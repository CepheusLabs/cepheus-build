"""Target execution, artifact collection, and repo synchronization."""

from __future__ import annotations

import glob
import shutil
import subprocess
from pathlib import Path

from .config import (
    ProductConfig,
    Stamp,
    git_output,
    git_try_output,
    host_list,
    resolve_path,
)
from .environment import build_env, target_env_values
from .errors import BuildError
from .flutter import (
    flutter_build_command,
    maybe_flutter_create,
    maybe_flutter_pub_get,
)
from .process import display_command, run_command, style_prefix
from .tools import ensure_host, require_target_tools

# Pre-build git housekeeping (status/pull/fetch) must not hang the build; bound
# every auxiliary git call below.
GIT_TIMEOUT = 120


def run_target(
    config: ProductConfig,
    target_name: str,
    stamp: Stamp,
    dry_run: bool,
    build_mode: str,
    extra_args: list[str],
    skip_unsupported: bool,
    extra_env: dict[str, str] | None = None,
    check_tools: bool = True,
) -> None:
    target = config.target(target_name)
    if not ensure_host(target_name, target, skip_unsupported):
        return
    if check_tools and not dry_run:
        require_target_tools(config, target_name, target)

    env = build_env(config, stamp, extra_env)
    env.update(target_env_values(target, env))
    print(f"\n{style_prefix('==>')} {config.display_name}: {target_name} ({stamp.full})")

    cwd = resolve_path(target.get("cwd", "."), config.repo_root)
    for command in host_list(target.get("pre")):
        run_command(str(command), cwd, env, dry_run)

    commands = host_list(target.get("commands"))
    if commands:
        for command in commands:
            run_command(str(command), cwd, env, dry_run)
    else:
        maybe_flutter_pub_get(config, target, env, dry_run)
        maybe_flutter_create(config, target_name, target, env, dry_run)
        command = flutter_build_command(config, target_name, target, stamp, env, build_mode, extra_args)
        run_command(command, config.app_dir, env, dry_run)

    for command in host_list(target.get("post")):
        run_command(str(command), cwd, env, dry_run)


def collect_artifacts(config: ProductConfig, target_names: list[str]) -> dict[str, list[Path]]:
    found: dict[str, list[Path]] = {}
    for target_name in target_names:
        target = config.target(target_name)
        paths = target.get("artifacts", []) or []
        target_found: list[Path] = []
        for raw in paths:
            pattern = str(resolve_path(str(raw), config.repo_root))
            matches = [Path(item) for item in glob.glob(pattern)]
            if matches:
                target_found.extend(matches)
            else:
                target_found.append(Path(pattern))
        found[target_name] = target_found
    return found


def run_git(args: list[str], cwd: Path, dry_run: bool = False) -> None:
    display = display_command("git", args)
    print(f"{style_prefix('+')} {display}", flush=True)
    if dry_run:
        return
    subprocess.run(["git", *args], cwd=cwd, check=True, timeout=GIT_TIMEOUT)


def try_run_git(args: list[str], cwd: Path, dry_run: bool = False) -> bool:
    display = display_command("git", args)
    print(f"{style_prefix('+')} {display}", flush=True)
    if dry_run:
        return True
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=GIT_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        print(f"warning: git {args[0]} timed out after {GIT_TIMEOUT}s", flush=True)
        return False
    if result.stdout:
        print(result.stdout, end="", flush=True)
    return result.returncode == 0


def remote_branch_exists(repo_root: Path, remote: str, branch: str) -> bool:
    ref = f"refs/remotes/{remote}/{branch}"
    try:
        result = subprocess.run(
            ["git", "show-ref", "--verify", "--quiet", ref],
            cwd=repo_root,
            timeout=GIT_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return False
    return result.returncode == 0


def working_tree_dirty(repo_root: Path) -> bool:
    """Return True if ``git status --porcelain`` reports uncommitted changes.

    On error or timeout, conservatively report not-dirty so the best-effort
    sync path is preserved; callers that demand a clean tree get the explicit
    ``require_clean`` check in :func:`sync_repo_before_build`.
    """

    output = git_try_output(["status", "--porcelain"], repo_root)
    return bool(output)


def sync_repo_before_build(
    repo_root: Path,
    dry_run: bool = False,
    require_clean: bool = False,
) -> None:
    if not repo_root.exists():
        raise BuildError(f"repo_root does not exist: {repo_root}")
    try:
        inside = git_output(["rev-parse", "--is-inside-work-tree"], repo_root)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        print(f"skip: {repo_root} is not a git worktree")
        return
    if inside.strip().lower() != "true":
        print(f"skip: {repo_root} is not a git worktree")
        return
    if working_tree_dirty(repo_root):
        if require_clean:
            raise BuildError(
                f"working tree at {repo_root} has uncommitted changes "
                "(--require-clean); commit or stash them first"
            )
        print(f"warning: {repo_root} has uncommitted changes; building a dirty tree")
    print(f"update: {repo_root}", flush=True)
    upstream = git_try_output(
        ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
        repo_root,
    )
    if upstream:
        if not try_run_git(["pull", "--ff-only"], repo_root, dry_run):
            print(
                f"warning: could not fast-forward {repo_root}; "
                "continuing with current checkout"
            )
    else:
        origin = git_try_output(["remote", "get-url", "origin"], repo_root)
        if not origin:
            print("skip: no origin remote configured; continuing without pull")
        else:
            branch = git_try_output(["branch", "--show-current"], repo_root)
            if branch:
                print(f"update: branch '{branch}' has no upstream; fetching origin")
            else:
                print("update: detached HEAD has no upstream; fetching origin")
            run_git(["fetch", "origin"], repo_root, dry_run)
            if branch and remote_branch_exists(repo_root, "origin", branch):
                ok = try_run_git(
                    ["pull", "--ff-only", "origin", branch],
                    repo_root,
                    dry_run,
                )
                if not ok:
                    print(
                        f"warning: could not fast-forward {repo_root}; "
                        "continuing with current checkout"
                    )
            elif branch:
                print(f"skip: origin/{branch} does not exist; continuing without pull")

def copy_artifact(source: Path, destination_root: Path, target_name: str) -> None:
    target_root = destination_root / target_name
    target_root.mkdir(parents=True, exist_ok=True)
    if not source.exists():
        return
    destination = target_root / source.name
    if source.is_dir():
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(source, destination)
    else:
        shutil.copy2(source, destination)
