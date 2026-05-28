"""Command-line driver for shared Cepheus Labs app builds."""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import os
import platform
import shlex
import shutil
import subprocess
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any


TOOL_ROOT = Path(__file__).resolve().parents[1]
PRODUCTS_DIR = TOOL_ROOT / "products"

DEFAULT_GROUPS: dict[str, list[str]] = {
    "desktop": ["macos", "windows", "linux"],
    "mobile": ["ios", "android"],
    "apple": ["ios", "macos"],
    "all": ["web", "android", "ios", "macos", "windows", "linux"],
}

HOST_ALIASES = {
    "darwin": "macos",
    "mac": "macos",
    "macos": "macos",
    "windows": "windows",
    "win32": "windows",
    "linux": "linux",
}


@dataclass(frozen=True)
class Stamp:
    version: str
    build_number: str

    @property
    def full(self) -> str:
        return f"{self.version}+{self.build_number}"


class BuildError(RuntimeError):
    """Raised when config or command execution fails."""


def current_host() -> str:
    return HOST_ALIASES.get(platform.system().lower(), platform.system().lower())


def shell_quote(value: str) -> str:
    if os.name == "nt":
        return value
    return shlex.quote(value)


def load_toml(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as handle:
            return tomllib.load(handle)
    except FileNotFoundError as exc:
        raise BuildError(f"Config not found: {path}") from exc
    except tomllib.TOMLDecodeError as exc:
        raise BuildError(f"Invalid TOML in {path}: {exc}") from exc


def resolve_path(raw: str | Path, base: Path) -> Path:
    expanded = os.path.expandvars(str(raw))
    path = Path(expanded).expanduser()
    if not path.is_absolute():
        path = base / path
    return path.resolve()


def find_config(product: str | None, config_path: str | None) -> Path:
    if config_path:
        return Path(config_path).expanduser().resolve()

    if product:
        candidate = PRODUCTS_DIR / f"{product}.toml"
        if candidate.exists():
            return candidate.resolve()
        direct = Path(product).expanduser()
        if direct.exists():
            return direct.resolve()
        raise BuildError(
            f"Unknown product '{product}'. Expected {candidate} or pass --config."
        )

    local = Path.cwd() / ".cepheus-build.toml"
    if local.exists():
        return local.resolve()

    raise BuildError("Pass --product, --config, or run inside a repo with .cepheus-build.toml.")


@dataclass
class ProductConfig:
    path: Path
    data: dict[str, Any]
    repo_root_override: str | None = None

    @property
    def product(self) -> dict[str, Any]:
        return self.data.get("product", {})

    @property
    def slug(self) -> str:
        return str(self.product.get("slug") or self.path.stem)

    @property
    def display_name(self) -> str:
        return str(self.product.get("display_name") or self.slug)

    @property
    def repo_root(self) -> Path:
        raw = self.repo_root_override or self.product.get("repo_root") or "."
        return resolve_path(str(raw), self.path.parent)

    @property
    def app_dir(self) -> Path:
        raw = self.product.get("app_dir") or "."
        return resolve_path(str(raw), self.repo_root)

    @property
    def flutter(self) -> dict[str, Any]:
        return self.data.get("flutter", {})

    @property
    def version(self) -> dict[str, Any]:
        return self.data.get("version", {})

    @property
    def targets(self) -> dict[str, Any]:
        return self.data.get("targets", {})

    @property
    def groups(self) -> dict[str, list[str]]:
        merged = {name: list(targets) for name, targets in DEFAULT_GROUPS.items()}
        for name, value in self.data.get("groups", {}).items():
            if isinstance(value, dict):
                targets = value.get("targets", [])
            else:
                targets = value
            merged[name] = list(targets)
        return merged

    @property
    def stores(self) -> dict[str, Any]:
        return self.data.get("stores", {})

    def target(self, name: str) -> dict[str, Any]:
        if name not in self.targets:
            raise BuildError(f"{self.slug} has no target named '{name}'.")
        target = self.targets[name] or {}
        if not bool(target.get("enabled", True)):
            raise BuildError(f"{self.slug} target '{name}' is disabled.")
        return target

    def expand_targets(self, requested: list[str]) -> list[str]:
        if not requested:
            requested = ["desktop"]
        expanded: list[str] = []
        for item in requested:
            for target in self.groups.get(item, [item]):
                if target in self.targets and target not in expanded:
                    target_cfg = self.targets[target] or {}
                    if bool(target_cfg.get("enabled", True)):
                        expanded.append(target)
        if not expanded:
            raise BuildError(f"No enabled targets matched: {', '.join(requested)}")
        return expanded


def git_output(args: list[str], cwd: Path) -> str:
    return subprocess.check_output(["git", *args], cwd=cwd, text=True).strip()


def compute_stamp(config: ProductConfig) -> Stamp:
    env_prefix = str(config.version.get("env_prefix") or config.slug).upper().replace("-", "_")
    version_env = os.getenv(f"{env_prefix}_BUILD_NAME") or os.getenv("CBUILD_VERSION")
    number_env = os.getenv(f"{env_prefix}_BUILD_NUMBER") or os.getenv("CBUILD_BUILD_NUMBER")
    if version_env and number_env:
        return Stamp(version_env, number_env)

    today = dt.datetime.now(dt.timezone.utc if config.version.get("utc", False) else None)
    default_version = f"{today.year % 100}.{today.month}.{today.day}"
    version = version_env or str(config.version.get("static_version") or default_version)

    if number_env:
        build = number_env
    else:
        try:
            build = git_output(["rev-list", "--count", "HEAD"], config.repo_root)
        except (subprocess.CalledProcessError, FileNotFoundError):
            build = os.getenv("GITHUB_RUN_NUMBER", "1")
    return Stamp(version, build)


def resolve_value(spec: Any, env: dict[str, str]) -> str:
    if isinstance(spec, dict):
        env_name = spec.get("env")
        default = spec.get("default", "")
        if env_name and env.get(str(env_name)) is not None:
            return str(env[str(env_name)])
        return str(default)
    value = str(spec)
    if value.startswith("env:"):
        payload = value[4:]
        if "=" in payload:
            env_name, default = payload.split("=", 1)
            return env.get(env_name, default)
        return env.get(payload, "")
    return os.path.expandvars(value)


def build_env(config: ProductConfig, stamp: Stamp) -> dict[str, str]:
    env = dict(os.environ)
    env_prefix = str(config.version.get("env_prefix") or config.slug).upper().replace("-", "_")
    existing_pythonpath = env.get("PYTHONPATH")
    env["PYTHONPATH"] = (
        str(TOOL_ROOT)
        if not existing_pythonpath
        else f"{TOOL_ROOT}{os.pathsep}{existing_pythonpath}"
    )
    env.update(
        {
            "CBUILD_PRODUCT": config.slug,
            "CBUILD_DISPLAY_NAME": config.display_name,
            "CBUILD_TOOL_ROOT": str(TOOL_ROOT),
            "CBUILD_REPO_ROOT": str(config.repo_root),
            "CBUILD_APP_DIR": str(config.app_dir),
            "CBUILD_VERSION": stamp.version,
            "CBUILD_BUILD_NUMBER": stamp.build_number,
            "CBUILD_FULL_VERSION": stamp.full,
            f"{env_prefix}_BUILD_NAME": stamp.version,
            f"{env_prefix}_BUILD_NUMBER": stamp.build_number,
        }
    )
    return env


def run_command(
    command: str,
    cwd: Path,
    env: dict[str, str],
    dry_run: bool = False,
) -> None:
    rendered = os.path.expandvars(command)
    print(f"+ {rendered}", flush=True)
    if dry_run:
        return
    subprocess.run(rendered, cwd=cwd, env=env, shell=True, check=True)


def ensure_host(target_name: str, target: dict[str, Any], skip_unsupported: bool) -> bool:
    hosts = target.get("hosts") or target.get("host")
    if not hosts:
        return True
    if isinstance(hosts, str):
        hosts = [hosts]
    allowed = {HOST_ALIASES.get(str(host).lower(), str(host).lower()) for host in hosts}
    host = current_host()
    if host in allowed or "any" in allowed:
        return True
    message = f"Target '{target_name}' requires {', '.join(sorted(allowed))}; current host is {host}."
    if skip_unsupported:
        print(f"skip: {message}")
        return False
    raise BuildError(message)


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


def run_target(
    config: ProductConfig,
    target_name: str,
    stamp: Stamp,
    dry_run: bool,
    build_mode: str,
    extra_args: list[str],
    skip_unsupported: bool,
) -> None:
    target = config.target(target_name)
    if not ensure_host(target_name, target, skip_unsupported):
        return

    env = build_env(config, stamp)
    print(f"\n==> {config.display_name}: {target_name} ({stamp.full})")

    cwd = resolve_path(target.get("cwd", "."), config.repo_root)
    for command in target.get("pre", []) or []:
        run_command(str(command), cwd, env, dry_run)

    commands = target.get("commands", []) or []
    if commands:
        for command in commands:
            run_command(str(command), cwd, env, dry_run)
    else:
        maybe_flutter_pub_get(config, target, env, dry_run)
        maybe_flutter_create(config, target_name, target, env, dry_run)
        command = flutter_build_command(config, target_name, target, stamp, env, build_mode, extra_args)
        run_command(command, config.app_dir, env, dry_run)

    for command in target.get("post", []) or []:
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


def cmd_list(_: argparse.Namespace) -> int:
    for path in sorted(PRODUCTS_DIR.glob("*.toml")):
        data = load_toml(path)
        config = ProductConfig(path=path, data=data)
        print(f"{config.slug}\t{config.display_name}")
    return 0


def cmd_plan(args: argparse.Namespace) -> int:
    config = load_product(args)
    stamp = compute_stamp(config)
    targets = config.expand_targets(args.targets)
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


def cmd_doctor(args: argparse.Namespace) -> int:
    config = load_product(args)
    targets = config.expand_targets(args.targets)
    print(product_summary(config))
    missing = False
    for path, label in [(config.repo_root, "repo_root"), (config.app_dir, "app_dir")]:
        if not path.exists():
            print(f"missing {label}: {path}")
            missing = True
    tools = set(config.data.get("tools", {}).get("required", []) or [])
    for target_name in targets:
        target = config.target(target_name)
        tools.update(target.get("tools", []) or [])
        if not ensure_host(target_name, target, skip_unsupported=True):
            continue
    for tool in sorted(tools):
        path = shutil.which(tool)
        print(f"{tool}: {path or 'missing'}")
        if not path:
            missing = True
    return 1 if missing else 0


def cmd_build(args: argparse.Namespace) -> int:
    config = load_product(args)
    targets = config.expand_targets(args.targets)
    stamp = compute_stamp(config)
    for target in targets:
        run_target(
            config=config,
            target_name=target,
            stamp=stamp,
            dry_run=args.dry_run,
            build_mode=args.mode,
            extra_args=args.flutter_arg or [],
            skip_unsupported=args.skip_unsupported,
        )
    return 0


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
    if not args.dry_run:
        for required in store.get("required_env", []) or []:
            if not env.get(str(required)):
                raise BuildError(f"Missing required environment variable for {args.store}: {required}")
    cwd = resolve_path(store.get("cwd", "."), config.repo_root)
    for command in store.get("commands", []) or []:
        run_command(str(command), cwd, env, args.dry_run)
    return 0


def add_product_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("-p", "--product", help="Product name from products/<name>.toml.")
    parser.add_argument("-c", "--config", help="Path to a product config TOML file.")
    parser.add_argument("--repo-root", help="Override product.repo_root. Useful in CI.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="cepheus-build")
    sub = parser.add_subparsers(dest="command", required=True)

    list_parser = sub.add_parser("list", help="List known shared product configs.")
    list_parser.set_defaults(func=cmd_list)

    plan = sub.add_parser("plan", help="Show the build plan for one product.")
    add_product_args(plan)
    plan.add_argument("targets", nargs="*", help="Targets or groups. Defaults to desktop.")
    plan.set_defaults(func=cmd_plan)

    stamp = sub.add_parser("stamp", help="Print the resolved version stamp.")
    add_product_args(stamp)
    stamp.add_argument("--github-output", action="store_true", help="Print key=value lines for GitHub outputs.")
    stamp.set_defaults(func=cmd_stamp)

    doctor = sub.add_parser("doctor", help="Check product paths and target tools.")
    add_product_args(doctor)
    doctor.add_argument("targets", nargs="*", help="Targets or groups. Defaults to desktop.")
    doctor.set_defaults(func=cmd_doctor)

    build = sub.add_parser("build", help="Build product targets.")
    add_product_args(build)
    build.add_argument("targets", nargs="*", help="Targets or groups. Defaults to desktop.")
    build.add_argument("--mode", choices=["release", "profile", "debug"], default="release")
    build.add_argument("--dry-run", action="store_true", help="Print commands without running them.")
    build.add_argument("--skip-unsupported", action="store_true", help="Skip targets that need another host OS.")
    build.add_argument(
        "--flutter-arg",
        action="append",
        default=[],
        help="Additional raw argument to pass to default Flutter build targets. Repeat as needed.",
    )
    build.set_defaults(func=cmd_build)

    artifacts = sub.add_parser("artifacts", help="List expected artifacts for targets.")
    add_product_args(artifacts)
    artifacts.add_argument("targets", nargs="*", help="Targets or groups. Defaults to desktop.")
    artifacts.add_argument("--copy-to", help="Copy existing artifacts into this directory by target.")
    artifacts.set_defaults(func=cmd_artifacts)

    deploy = sub.add_parser("deploy", help="Run configured store deployment commands.")
    add_product_args(deploy)
    deploy.add_argument("store", help="Store name from [stores.<name>].")
    deploy.add_argument("--dry-run", action="store_true", help="Print commands without running them.")
    deploy.set_defaults(func=cmd_deploy)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except BuildError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as exc:
        print(f"error: command failed with exit code {exc.returncode}", file=sys.stderr)
        return exc.returncode or 1
