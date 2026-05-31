"""Flutter build command construction."""

from __future__ import annotations

from typing import Any

from .config import ProductConfig, Stamp
from .environment import resolve_value
from .process import run_command, shell_quote


def dart_define_args(config: ProductConfig, target: dict[str, Any], env: dict[str, str]) -> list[str]:
    values: dict[str, Any] = {}
    values.update(config.flutter.get("dart_defines", {}) or {})
    values.update(target.get("dart_defines", {}) or {})
    args: list[str] = []
    for key, spec in values.items():
        resolved = resolve_value(spec, env)
        if resolved != "":
            args.append(f"--dart-define={key}={resolved}")
    return args


def flutter_build_command(
    config: ProductConfig,
    target_name: str,
    target: dict[str, Any],
    stamp: Stamp,
    env: dict[str, str],
    build_mode: str,
    extra_args: list[str],
) -> str:
    flutter_bin = str(config.flutter.get("binary") or "flutter")
    flutter_target = str(target.get("flutter") or target_name)
    args: list[str] = ["build", flutter_target]
    if build_mode:
        args.append(f"--{build_mode}")
    args.extend(str(item) for item in target.get("flutter_args", []) or [])
    args.extend(dart_define_args(config, target, env))

    if bool(target.get("version_flags", True)):
        args.append(f"--build-name={stamp.version}")
        args.append(f"--build-number={stamp.build_number}")

    args.extend(extra_args)
    return " ".join([shell_quote(flutter_bin), *[shell_quote(arg) for arg in args]])


def maybe_flutter_pub_get(config: ProductConfig, target: dict[str, Any], env: dict[str, str], dry_run: bool) -> None:
    if not bool(config.flutter.get("pub_get", True)):
        return
    if target.get("pub_get") is False:
        return
    flutter_bin = str(config.flutter.get("binary") or "flutter")
    run_command(f"{shell_quote(flutter_bin)} pub get", config.app_dir, env, dry_run)


def maybe_flutter_create(config: ProductConfig, target_name: str, target: dict[str, Any], env: dict[str, str], dry_run: bool) -> None:
    create_platform = target.get("create_platform")
    if not create_platform and not bool(config.flutter.get("create_platforms", False)):
        return
    platform_name = str(create_platform or target.get("flutter") or target_name)
    project_name = str(config.flutter.get("project_name") or config.slug.replace("-", "_"))
    flutter_bin = str(config.flutter.get("binary") or "flutter")
    command = (
        f"{shell_quote(flutter_bin)} create "
        f"--platforms={shell_quote(platform_name)} "
        f"--project-name={shell_quote(project_name)} ."
    )
    run_command(command, config.app_dir, env, dry_run)
