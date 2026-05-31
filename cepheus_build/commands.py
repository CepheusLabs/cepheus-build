"""Subcommand implementations for the Cepheus build CLI."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

from .builder import (
    collect_artifacts,
    copy_artifact,
    run_target,
    sync_repo_before_build,
)
from .config import (
    PRODUCTS_DIR,
    ProductConfig,
    compute_stamp,
    current_host,
    find_config,
    host_list,
    load_toml,
    normalize_hosts,
    resolve_path,
)
from .environment import build_env
from .errors import BuildError
from .github import (
    build_ci_matrix,
    buildroot_env,
    cmd_github_build,
    default_github_workflow,
    runner_profile_config,
    runner_profile_names,
)
from .process import run_command
from .tools import ensure_host, install_deps_for_targets, tool_status


def product_summary(config: ProductConfig) -> str:
    targets = ", ".join(sorted(name for name, target in config.targets.items() if bool((target or {}).get("enabled", True))))
    stores = ", ".join(sorted(config.stores)) or "none"
    return (
        f"{config.display_name} ({config.slug})\n"
        f"  config: {config.path}\n"
        f"  repo:   {config.repo_root}\n"
        f"  app:    {config.app_dir}\n"
        f"  targets: {targets}\n"
        f"  stores:  {stores}"
    )


def load_product(args: argparse.Namespace) -> ProductConfig:
    path = find_config(getattr(args, "product", None), getattr(args, "config", None))
    return ProductConfig(path=path, data=load_toml(path), repo_root_override=getattr(args, "repo_root", None))


def cmd_list(args: argparse.Namespace) -> int:
    configs = [
        ProductConfig(path=path, data=load_toml(path))
        for path in sorted(PRODUCTS_DIR.glob("*.toml"))
    ]
    if getattr(args, "json", False):
        payload = [
            {"slug": config.slug, "display_name": config.display_name}
            for config in configs
        ]
        print(json.dumps(payload))
        return 0
    for config in configs:
        print(f"{config.slug}\t{config.display_name}")
    return 0


def _plan_target_hosts(target: dict) -> list[str]:
    raw = target.get("hosts") or target.get("host")
    if not raw:
        return ["any"]
    if isinstance(raw, str):
        return [raw]
    return [str(host) for host in raw]


def _plan_target_mode(target: dict) -> str:
    """build/skip for the current host, mirroring ensure_host's decision."""
    allowed = normalize_hosts(target.get("hosts") or target.get("host"))
    return "build" if current_host() in allowed else "skip"


def cmd_plan(args: argparse.Namespace) -> int:
    config = load_product(args)
    stamp = compute_stamp(config)
    targets = config.expand_targets(args.targets)
    if getattr(args, "json", False):
        target_rows = []
        for target_name in targets:
            target = config.target(target_name)
            target_rows.append(
                {
                    "name": target_name,
                    "mode": _plan_target_mode(target),
                    "hosts": _plan_target_hosts(target),
                    "artifacts": [str(a) for a in (target.get("artifacts") or [])],
                }
            )
        print(
            json.dumps(
                {"product": config.slug, "stamp": stamp.full, "targets": target_rows}
            )
        )
        return 0
    print(product_summary(config))
    print(f"  stamp:  {stamp.full}")
    print()
    for target_name in targets:
        target = config.target(target_name)
        hosts = target.get("hosts") or target.get("host") or ["any"]
        if isinstance(hosts, str):
            hosts = [hosts]
        mode = "custom commands" if target.get("commands") else f"flutter build {target.get('flutter', target_name)}"
        print(f"- {target_name}: {mode} on {', '.join(hosts)}")
        for artifact in target.get("artifacts", []) or []:
            print(f"  artifact: {artifact}")
    return 0


def cmd_stamp(args: argparse.Namespace) -> int:
    config = load_product(args)
    stamp = compute_stamp(config)
    if args.github_output:
        print(f"version={stamp.version}")
        print(f"build_number={stamp.build_number}")
        print(f"full_version={stamp.full}")
        print(f"tag=v{stamp.version}-{stamp.build_number}")
    else:
        print(stamp.full)
    return 0


def _runner_profile_options() -> list[dict[str, str]]:
    """[{"value","label"}] for every runner profile in build.toml.

    Labels come from each profile's optional ``label`` key; otherwise the
    profile name is reused as a human-readable fallback.
    """
    options: list[dict[str, str]] = []
    for name in runner_profile_names():
        profile = runner_profile_config(name)
        label = profile.get("label", name)
        options.append({"value": name, "label": str(label)})
    return options


def _target_choices(config: ProductConfig) -> list[str]:
    """Group names followed by enabled target names, deduped, order-preserving.

    Mirrors the app's union of selectable groups and targets.
    """
    choices: list[str] = []
    for name in config.groups:
        if name not in choices:
            choices.append(name)
    for name, target in config.targets.items():
        if bool((target or {}).get("enabled", True)) and name not in choices:
            choices.append(name)
    return choices


def _describe_target(target: dict) -> dict:
    return {
        "enabled": bool((target or {}).get("enabled", True)),
        "hosts": normalize_hosts((target or {}).get("hosts") or (target or {}).get("host")),
        "tools": host_list((target or {}).get("tools")),
    }


def _describe_store(store: dict) -> dict:
    return {
        "enabled": bool((store or {}).get("enabled", True)),
        "hosts": normalize_hosts((store or {}).get("hosts") or (store or {}).get("host")),
        "required_env": [str(v) for v in ((store or {}).get("required_env") or [])],
    }


def _describe_product(config: ProductConfig) -> dict:
    workflow = config.github.get("workflow") or config.github.get("default_workflow")
    if not workflow:
        try:
            workflow = default_github_workflow(config)
        except BuildError:
            workflow = None
    return {
        "slug": config.slug,
        "display_name": config.display_name,
        "repo_root": str(config.repo_root),
        "app_dir": str(config.app_dir),
        "github": {
            "repository": config.github.get("repository") or config.github.get("repo"),
            "workflow": workflow,
        },
        "groups": {name: list(members) for name, members in config.groups.items()},
        "targets": {
            name: _describe_target(target or {})
            for name, target in config.targets.items()
        },
        "stores": {
            name: _describe_store(store or {})
            for name, store in config.stores.items()
        },
        "runner_profiles": _runner_profile_options(),
        "target_choices": _target_choices(config),
    }


def cmd_describe(args: argparse.Namespace) -> int:
    """Emit machine-readable JSON describing products or a single product.

    Two forms (JSON is the only output for now; ``--json`` is accepted but the
    command always emits JSON):
      * ``describe``            -> products + runner profiles overview
      * ``describe -p <slug>``  -> full per-product description
    """
    if getattr(args, "product", None) or getattr(args, "config", None):
        config = load_product(args)
        print(json.dumps(_describe_product(config)))
        return 0

    payload = {
        "products": [
            {"slug": config.slug, "display_name": config.display_name}
            for config in (
                ProductConfig(path=path, data=load_toml(path))
                for path in sorted(PRODUCTS_DIR.glob("*.toml"))
            )
        ],
        "runner_profiles": _runner_profile_options(),
    }
    print(json.dumps(payload))
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    config = load_product(args)
    targets = config.expand_targets(args.targets)
    json_mode = getattr(args, "json", False)

    repo_root = config.repo_root
    app_dir = config.app_dir
    repo_exists = repo_root.exists()
    app_exists = app_dir.exists()

    if not json_mode:
        print(product_summary(config))
        for path, label, exists in [
            (repo_root, "repo_root", repo_exists),
            (app_dir, "app_dir", app_exists),
        ]:
            if not exists:
                print(f"missing {label}: {path}")

    missing_paths = not (repo_exists and app_exists)

    tools = set(config.data.get("tools", {}).get("required", []) or [])
    for target_name in targets:
        target = config.target(target_name)
        tools.update(host_list(target.get("tools")))
        if not ensure_host(target_name, target, skip_unsupported=True):
            continue

    tool_rows = [(tool, *tool_status(tool)) for tool in sorted(tools)]
    missing_tools = [tool for tool, ok, _ in tool_rows if not ok]
    all_ok = not missing_paths and not missing_tools

    if json_mode:
        payload = {
            "product": config.slug,
            "ok": all_ok,
            "paths": {
                "repo_root": {"path": str(repo_root), "exists": repo_exists},
                "app_dir": {"path": str(app_dir), "exists": app_exists},
            },
            "tools": [
                {"name": tool, "ok": ok, "detail": detail}
                for tool, ok, detail in tool_rows
            ],
        }
        print(json.dumps(payload))
        return 0 if all_ok else 1

    for tool, _ok, detail in tool_rows:
        print(f"{tool}: {detail}")

    if missing_tools:
        print(
            "hint: install missing tools with: "
            f"cepheus-build install-deps -p {config.slug} {' '.join(targets)}"
        )

    return 0 if all_ok else 1


def cmd_install_deps(args: argparse.Namespace) -> int:
    config = load_product(args)
    targets = config.expand_targets(args.targets)
    return install_deps_for_targets(
        config,
        targets,
        dry_run=args.dry_run,
        skip_existing=args.skip_existing,
        skip_unsupported=args.skip_unsupported,
    )


def command_failure_message(exc: Exception) -> str:
    if isinstance(exc, subprocess.CalledProcessError):
        return f"command failed with exit code {exc.returncode}"
    return str(exc)


def cmd_build(args: argparse.Namespace) -> int:
    config = load_product(args)
    if args.execution_mode == "github":
        return cmd_github_build(config, args)

    targets = config.expand_targets(args.targets)
    if not args.dry_run and not getattr(args, "no_sync", False):
        sync_repo_before_build(
            config.repo_root, require_clean=getattr(args, "require_clean", False)
        )
    stamp = compute_stamp(config)
    extra_env = buildroot_env(args)
    failures: list[tuple[str, str]] = []
    for target in targets:
        try:
            target_config = config.target(target)
            if not ensure_host(target, target_config, skip_unsupported=args.skip_unsupported):
                continue
            if args.install_missing_deps:
                install_deps_for_targets(
                    config,
                    [target],
                    dry_run=args.dry_run,
                    skip_existing=True,
                    skip_unsupported=False,
                    quiet_existing=True,
                    quiet_empty=True,
                )
            run_target(
                config=config,
                target_name=target,
                stamp=stamp,
                dry_run=args.dry_run,
                build_mode=args.mode,
                extra_args=args.flutter_arg or [],
                skip_unsupported=False,
                extra_env=extra_env,
                check_tools=args.check_tools,
            )
        except (BuildError, subprocess.CalledProcessError) as exc:
            message = command_failure_message(exc)
            failures.append((target, message))
            print(f"failed: {target}: {message}", file=sys.stderr)
            if not args.keep_going:
                raise
    if failures:
        print("\n## Build summary")
        for target, message in failures:
            print(f"failed: {target}: {message}")
        return 1
    return 0


def cmd_artifacts(args: argparse.Namespace) -> int:
    config = load_product(args)
    targets = config.expand_targets(args.targets)
    artifacts = collect_artifacts(config, targets)
    copy_to = resolve_path(args.copy_to, Path.cwd()) if args.copy_to else None
    for target, paths in artifacts.items():
        print(f"{target}:")
        for path in paths:
            marker = "ok" if path.exists() else "missing"
            print(f"  [{marker}] {path}")
            if copy_to and path.exists():
                copy_artifact(path, copy_to, target)
    if copy_to:
        print(f"copied artifacts to {copy_to}")
    return 0


def cmd_deploy(args: argparse.Namespace) -> int:
    config = load_product(args)
    stamp = compute_stamp(config)
    store = config.stores.get(args.store)
    if not store:
        raise BuildError(f"{config.slug} has no store named '{args.store}'.")
    if not bool(store.get("enabled", True)):
        raise BuildError(f"{config.slug} store '{args.store}' is disabled.")
    ensure_host(args.store, store, skip_unsupported=False)
    env = build_env(config, stamp)
    if args.dry_run:
        # Thread the dry-run intent into the lane so a deploy module that
        # supports it (e.g. cepheus_build.deploy.google_play) can preview
        # instead of performing a real upload. run_command still echoes each
        # command with the leading "+ " prefix and skips execution.
        env["CBUILD_DRY_RUN"] = "1"
    else:
        for required in store.get("required_env", []) or []:
            if not env.get(str(required)):
                raise BuildError(f"Missing required environment variable for {args.store}: {required}")
    cwd = resolve_path(store.get("cwd", "."), config.repo_root)
    for command in host_list(store.get("commands")):
        run_command(str(command), cwd, env, args.dry_run)
    return 0


def cmd_ci_matrix(args: argparse.Namespace) -> int:
    config = load_product(args)
    requested = args.targets or ["all"]
    targets = config.expand_targets(requested)
    matrix = build_ci_matrix(config, targets, args.runner_profile)
    if args.pretty:
        print(json.dumps(matrix, indent=2))
    else:
        print(json.dumps(matrix, separators=(",", ":")))
    return 0


def all_product_names() -> list[str]:
    return [path.stem for path in sorted(PRODUCTS_DIR.glob("*.toml"))]


def cmd_local_sweep(args: argparse.Namespace) -> int:
    product_names = args.products or all_product_names()
    excluded = set(args.exclude or [])
    product_names = [name for name in product_names if name not in excluded]
    if not product_names:
        raise BuildError("No products selected for local-sweep.")

    failures: list[tuple[str, str]] = []
    for product_name in product_names:
        config_path = find_config(product_name, None)
        config = ProductConfig(
            path=config_path,
            data=load_toml(config_path),
        )
        extra_env = buildroot_env(args)
        print(f"\n## {config.display_name} ({product_name})")
        try:
            if not args.dry_run and not getattr(args, "no_sync", False):
                sync_repo_before_build(
                    config.repo_root,
                    require_clean=getattr(args, "require_clean", False),
                )
            stamp = compute_stamp(config)
            targets = config.expand_targets(args.targets or ["desktop"])
            for target in targets:
                target_config = config.target(target)
                if not ensure_host(target, target_config, skip_unsupported=args.skip_unsupported):
                    continue
                if args.install_missing_deps:
                    install_deps_for_targets(
                        config,
                        [target],
                        dry_run=args.dry_run,
                        skip_existing=True,
                        skip_unsupported=False,
                        quiet_existing=True,
                        quiet_empty=True,
                    )
                run_target(
                    config=config,
                    target_name=target,
                    stamp=stamp,
                    dry_run=args.dry_run,
                    build_mode=args.mode,
                    extra_args=args.flutter_arg or [],
                    skip_unsupported=False,
                    extra_env=extra_env,
                    check_tools=args.check_tools,
                )
        except (BuildError, subprocess.CalledProcessError) as exc:
            message = command_failure_message(exc)
            failures.append((product_name, message))
            print(f"failed: {product_name}: {message}", file=sys.stderr)
            if not args.keep_going:
                break

    print("\n## Local sweep summary")
    if not failures:
        print(f"ok: {', '.join(product_names)}")
        return 0
    for product_name, message in failures:
        print(f"failed: {product_name}: {message}")
    return 1
