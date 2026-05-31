"""GitHub workflow dispatch and CI matrix generation."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any

from .config import (
    HOST_ORDER,
    TOOL_ROOT,
    ProductConfig,
    git_output,
    host_list,
    load_tool_config,
    normalize_hosts,
)
from .errors import BuildError
from .process import display_command, style_prefix

# The ``gh`` dispatch is a single short network call; bound it so a stalled
# request (auth prompt, hung connection) surfaces as a clear error.
GH_TIMEOUT = 120


def github_config() -> dict[str, Any]:
    return load_tool_config().get("github", {})


def runner_profile_names() -> list[str]:
    profiles = github_config().get("runner_profiles", {})
    return sorted(profiles)


def runner_profile_config(profile: str) -> dict[str, Any]:
    profiles = github_config().get("runner_profiles", {})
    profile_config = profiles.get(profile)
    if not isinstance(profile_config, dict):
        known = ", ".join(sorted(profiles)) or "none"
        raise BuildError(f"Unknown runner profile '{profile}'. Known profiles: {known}")
    return profile_config


def runner_map(profile: str) -> dict[str, str | list[str]]:
    profile_config = runner_profile_config(profile)
    runners: dict[str, str | list[str]] = {}
    for host in HOST_ORDER:
        value = profile_config.get(host)
        if value:
            runners[host] = value
    if not runners:
        raise BuildError(f"Runner profile '{profile}' does not define any host runners.")
    return runners


def planner_runner_json(profile: str) -> str:
    profile_config = runner_profile_config(profile)
    planner = profile_config.get("planner") or profile_config.get("linux")
    if not planner:
        raise BuildError(f"Runner profile '{profile}' does not define planner or linux runner.")
    return json.dumps(planner, separators=(",", ":"))


def default_github_workflow(config: ProductConfig) -> str:
    workflow = config.github.get("workflow") or github_config().get("default_workflow")
    if not workflow:
        raise BuildError("No GitHub workflow configured. Set [github].default_workflow in build.toml or [github].workflow in the product config.")
    return str(workflow)


def github_repo_from_remote(url: str) -> str | None:
    stripped = url.strip()
    patterns = [
        r"^https://github\.com/(?P<repo>[^/]+/[^/.]+)(?:\.git)?/?$",
        r"^git@github\.com:(?P<repo>[^/]+/[^/.]+)(?:\.git)?$",
        r"^ssh://git@github\.com/(?P<repo>[^/]+/[^/.]+)(?:\.git)?/?$",
    ]
    for pattern in patterns:
        match = re.match(pattern, stripped)
        if match:
            return match.group("repo")
    return None


def detected_github_repo(repo_root: Path) -> str | None:
    try:
        remote = git_output(["remote", "get-url", "origin"], repo_root)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    return github_repo_from_remote(remote)


def github_repository(config: ProductConfig, override: str | None = None) -> str:
    if override and override.strip():
        return override.strip()
    configured = config.github.get("repository") or config.github.get("repo")
    if configured:
        return str(configured)
    detected = detected_github_repo(config.repo_root)
    if detected:
        return detected
    raise BuildError(
        "No GitHub repository configured. Pass --github-repo, add [github].repository to the product config, or set an origin remote on the product repo."
    )


def bool_input(value: bool) -> str:
    return "true" if value else "false"


def buildroot_env(args: argparse.Namespace) -> dict[str, str]:
    buildroot_dir = getattr(args, "buildroot_dir", "") or ""
    if not buildroot_dir.strip():
        return {}
    return {"BUILDROOT_DIR": buildroot_dir.strip()}


def github_dispatch_args(config: ProductConfig, args: argparse.Namespace) -> list[str]:
    workflow = getattr(args, "github_workflow", "") or default_github_workflow(config)
    repo = github_repository(config, getattr(args, "github_repo", None))
    requested_targets = getattr(args, "targets", None) or ["desktop"]
    dispatch_args = [
        "workflow",
        "run",
        workflow,
        "-R",
        repo,
        "-f",
        f"targets={' '.join(requested_targets)}",
        "-f",
        f"runner-profile={args.runner_profile}",
        "-f",
        f"mode={args.mode}",
        "-f",
        f"planner-runner-json={args.planner_runner_json or planner_runner_json(args.runner_profile)}",
    ]
    if config.slug == "foundry":
        dispatch_args.extend(
            [
                "-f",
                f"setup-buildroot-deps={bool_input(args.setup_buildroot_deps)}",
            ]
        )
        buildroot_dir = args.buildroot_dir.strip()
        if buildroot_dir:
            dispatch_args.extend(["-f", f"buildroot-dir={buildroot_dir}"])
    return dispatch_args


def cmd_github_build(config: ProductConfig, args: argparse.Namespace) -> int:
    dispatch_args = github_dispatch_args(config, args)
    display = display_command("gh", dispatch_args)
    print(f"{style_prefix('+')} {display}")
    if args.dry_run:
        return 0
    cwd = config.repo_root if getattr(args, "repo_root", None) else TOOL_ROOT
    if not cwd.exists():
        cwd = TOOL_ROOT
    try:
        subprocess.run(["gh", *dispatch_args], cwd=cwd, check=True, timeout=GH_TIMEOUT)
    except subprocess.TimeoutExpired as exc:
        raise BuildError(f"gh workflow run timed out after {GH_TIMEOUT}s") from exc
    return 0


def preferred_host_for_target(target_name: str, target: dict[str, Any]) -> str | None:
    allowed = normalize_hosts(target.get("hosts") or target.get("host"))
    preferences = normalize_hosts(
        target.get("ci_hosts")
        or target.get("preferred_hosts")
        or target.get("preferred_host")
        or allowed
    )
    for host in preferences:
        if host in allowed:
            return host
    for host in HOST_ORDER:
        if host in allowed:
            return host
    return None


def build_ci_matrix(
    config: ProductConfig,
    target_names: list[str],
    profile: str,
) -> dict[str, list[dict[str, Any]]]:
    runners = runner_map(profile)
    rows_by_host: dict[str, list[str]] = {host: [] for host in HOST_ORDER}
    targets_by_name = {target_name: config.target(target_name) for target_name in target_names}
    for target_name in target_names:
        target = targets_by_name[target_name]
        host = preferred_host_for_target(target_name, target)
        if host and host in runners:
            rows_by_host[host].append(target_name)

    rows: list[dict[str, Any]] = []
    for host in HOST_ORDER:
        targets = rows_by_host[host]
        if not targets:
            continue
        tools = {
            str(tool)
            for target_name in targets
            for tool in host_list(targets_by_name[target_name].get("tools"), host)
        }
        rows.append(
            {
                "name": host,
                "host": host,
                "runner": runners[host],
                "targets": " ".join(targets),
                "setup_flutter": "flutter" in tools,
                "setup_go": "go" in tools,
                "setup_rust": bool({"cargo", "rustup", "cargo-ndk", "wasm-pack"} & tools),
                "setup_cargo_ndk": "cargo-ndk" in tools,
                "setup_wasm_pack": "wasm-pack" in tools,
                "setup_buildroot": "buildroot" in tools,
            }
        )
    if not rows:
        raise BuildError("No CI matrix rows could be generated for the requested targets.")
    return {"include": rows}
