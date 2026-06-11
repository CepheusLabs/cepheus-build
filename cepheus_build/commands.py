"""Subcommand implementations for the Cepheus build CLI."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

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
from .container import (
    cmd_container_build,
    container_profile_config,
    container_profile_names,
)
from .dependency_model import (
    dependency_audit_issues,
    dependency_outputs,
    missing_local_paths,
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
from .validation import validate_product_data


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
    if getattr(args, "json", False):
        print(json.dumps({
            "version": stamp.version,
            "build_number": stamp.build_number,
            "full_version": stamp.full,
            "tag": f"v{stamp.version}-{stamp.build_number}",
        }))
    elif args.github_output:
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


def _container_profile_options() -> list[dict[str, str]]:
    """[{"value","label"}] for every container/VM profile in build.toml."""
    options: list[dict[str, str]] = []
    for name in container_profile_names():
        profile = container_profile_config(name)
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
        "container_profiles": _container_profile_options(),
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
        "container_profiles": _container_profile_options(),
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


def _deps_repo_root(config: ProductConfig, workspace_root: Path) -> Path:
    workspace_checkout = (workspace_root / config.slug).resolve()
    if workspace_checkout.exists():
        return workspace_checkout
    return config.repo_root


def cmd_deps(args: argparse.Namespace) -> int:
    config = load_product(args)
    workspace_root = Path(args.workspace_root).expanduser().resolve() if args.workspace_root else config.repo_root.parent
    repo_root = _deps_repo_root(config, workspace_root)
    audit_committed = bool(getattr(args, "audit_committed", False))
    try:
        audit_issues = dependency_audit_issues(config.slug, repo_root)
        outputs = [] if audit_committed else dependency_outputs(config.slug, repo_root, workspace_root)
        missing = [] if audit_committed else missing_local_paths(config.slug, workspace_root)
    except KeyError as exc:
        raise BuildError(str(exc)) from exc

    rows = []
    changed = False
    for output in outputs:
        current = output.path.read_text() if output.path.exists() else None
        matches = current == output.content
        if args.write and not matches:
            output.path.parent.mkdir(parents=True, exist_ok=True)
            output.path.write_text(output.content)
            current = output.content
            matches = True
        changed = changed or not matches
        rows.append(
            {
                "kind": output.kind,
                "path": str(output.path),
                "exists": output.path.exists(),
                "matches": matches,
            }
        )

    ok = not missing and not changed and not audit_issues
    if getattr(args, "json", False):
        print(
            json.dumps(
                {
                    "product": config.slug,
                    "workspace_root": str(workspace_root),
                    "ok": ok,
                    "written": bool(args.write),
                    "outputs": rows,
                    "missing_local_paths": [str(path) for path in missing],
                    "committed_manifest_issues": [
                        {
                            "path": str(issue.path),
                            "code": issue.code,
                            "message": issue.message,
                        }
                        for issue in audit_issues
                    ],
                }
            )
        )
        return 0 if ok else 1

    print(f"{config.display_name} ({config.slug})")
    print(f"  repo:           {repo_root}")
    print(f"  workspace_root: {workspace_root}")
    for row in rows:
        status = "ok" if row["matches"] else ("write" if args.write else "stale/missing")
        print(f"{status}: {row['path']}")
    if missing:
        print("missing local package paths:")
        for path in missing:
            print(f"  - {path}")
    if audit_issues:
        print("committed dependency model issues:")
        for issue in audit_issues:
            print(f"  - {issue.path}: {issue.code}: {issue.message}")
    elif audit_committed:
        print("committed dependency model is clean")
    elif args.write:
        print("local dependency override files are current")
    else:
        print("run with --write to create/update ignored local override files")
    return 0 if ok else 1


def cmd_gopins(args: argparse.Namespace) -> int:
    from . import gopins

    repos = [Path(r).expanduser().resolve() for r in (args.repo or ["."])]
    payload: list[dict[str, Any]] = []
    failures: list[str] = []
    any_stale = False

    for repo in repos:
        go_mod = repo / "go.mod"
        if not go_mod.exists():
            raise BuildError(f"no go.mod in {repo}")
        workspace_root = (
            Path(args.workspace_root).expanduser().resolve() if args.workspace_root else repo.parent
        )
        rows = gopins.plan(go_mod.read_text(), workspace_root)
        if args.write:
            failures.extend(gopins.apply(rows, repo))
            rows = gopins.plan(go_mod.read_text(), workspace_root)
        stale = [row for row in rows if row.status == gopins.STATUS_STALE]
        any_stale = any_stale or bool(stale)
        payload.append(
            {
                "repo": str(repo),
                "workspace_root": str(workspace_root),
                "pins": [
                    {
                        "module": row.module,
                        "version": row.version,
                        "status": row.status,
                        "pinned_sha": row.pinned_sha,
                        "head_sha": row.head_sha,
                        "indirect": row.indirect,
                    }
                    for row in rows
                ],
                "stale": len(stale),
            }
        )

    ok = not failures and (args.write or not any_stale)
    if getattr(args, "json", False):
        print(json.dumps({"ok": ok, "written": bool(args.write), "failures": failures, "repos": payload}))
        return 0 if ok else 1

    for entry in payload:
        print(f"{entry['repo']}  (siblings: {entry['workspace_root']})")
        for pin in entry["pins"]:
            indirect = " (indirect)" if pin["indirect"] else ""
            print(f"  {pin['status']:>15}: {pin['module']} {pin['version']}{indirect}")
        print(f"  stale: {entry['stale']}")
    for failure in failures:
        print(f"FAILED: {failure}")
    if any_stale and not args.write:
        print("run with --write to advance stale pins (go get module@HEAD + go mod tidy, GOWORK=off)")
    return 0 if ok else 1


def command_failure_message(exc: Exception) -> str:
    if isinstance(exc, subprocess.CalledProcessError):
        return f"command failed with exit code {exc.returncode}"
    return str(exc)


def cmd_build(args: argparse.Namespace) -> int:
    config = load_product(args)
    if args.execution_mode == "github":
        return cmd_github_build(config, args)
    if args.execution_mode == "container":
        return cmd_container_build(config, args)

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
    json_mode = getattr(args, "json", False)
    payload: dict[str, list[dict[str, Any]]] = {}
    for target, paths in artifacts.items():
        if not json_mode:
            print(f"{target}:")
        rows: list[dict[str, Any]] = []
        for path in paths:
            exists = path.exists()
            if not json_mode:
                print(f"  [{'ok' if exists else 'missing'}] {path}")
            rows.append({"path": str(path), "exists": exists})
            if copy_to and exists:
                copy_artifact(path, copy_to, target)
        payload[target] = rows
    if json_mode:
        print(json.dumps({"copy_to": str(copy_to) if copy_to else None, "targets": payload}))
    elif copy_to:
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


def cmd_validate(args: argparse.Namespace) -> int:
    """Validate product config(s) against schemas/product.schema.json.

    With ``-p``/``--config`` validates that one config; otherwise validates
    every config in products/. Exits non-zero if any config has errors.
    """
    if getattr(args, "product", None) or getattr(args, "config", None):
        path = find_config(getattr(args, "product", None), getattr(args, "config", None))
        paths = [path]
    else:
        paths = sorted(PRODUCTS_DIR.glob("*.toml"))

    results: list[dict[str, Any]] = []
    ok = True
    for path in paths:
        try:
            data = load_toml(path)
            errors = validate_product_data(data)
        except BuildError as exc:
            errors = [str(exc)]
        if errors:
            ok = False
        results.append({"config": str(path), "valid": not errors, "errors": errors})

    if getattr(args, "json", False):
        print(json.dumps({"ok": ok, "results": results}))
        return 0 if ok else 1

    for result in results:
        name = Path(result["config"]).stem
        if result["valid"]:
            print(f"ok: {name}")
        else:
            print(f"invalid: {name}")
            for err in result["errors"]:
                print(f"  - {err}")
    if not ok:
        print("\nSome configs failed validation.")
    return 0 if ok else 1


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
            if getattr(args, "execution_mode", "local") == "container":
                if cmd_container_build(config, args) != 0:
                    failures.append((product_name, "container build failed"))
                    if not args.keep_going:
                        break
                continue
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
