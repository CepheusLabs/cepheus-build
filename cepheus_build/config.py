"""Product configuration, host detection, and version stamping."""

from __future__ import annotations

import datetime as dt
import functools
import os
import platform
import subprocess
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .errors import BuildError


TOOL_ROOT = Path(__file__).resolve().parents[1]
PRODUCTS_DIR = TOOL_ROOT / "products"
TOOL_CONFIG_PATH = TOOL_ROOT / "build.toml"

# Auxiliary git invocations (rev-list, etc.) must never hang the CLI.
GIT_TIMEOUT = 120

HOST_ALIASES = {
    "darwin": "macos",
    "mac": "macos",
    "macos": "macos",
    "windows": "windows",
    "win32": "windows",
    "linux": "linux",
}

HOST_ORDER = ["linux", "macos", "windows"]

VIRTUAL_TOOLS = {"buildroot"}

@dataclass(frozen=True)
class Stamp:
    version: str
    build_number: str

    @property
    def full(self) -> str:
        return f"{self.version}+{self.build_number}"


def current_host() -> str:
    return HOST_ALIASES.get(platform.system().lower(), platform.system().lower())


def load_toml(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as handle:
            return tomllib.load(handle)
    except FileNotFoundError as exc:
        raise BuildError(f"Config not found: {path}") from exc
    except tomllib.TOMLDecodeError as exc:
        raise BuildError(f"Invalid TOML in {path}: {exc}") from exc


@functools.lru_cache(maxsize=1)
def load_tool_config() -> dict[str, Any]:
    # Cached for the lifetime of the process: ``build.toml`` lives at a constant
    # path and is consulted once per tool check and per GitHub query, so reading
    # it repeatedly is wasteful. The cache is process-scoped, which is correct
    # for a short-lived CLI invocation; a fresh run always re-reads the file.
    # ``load_toml`` (used for product configs) stays uncached because its paths
    # vary per product.
    return load_toml(TOOL_CONFIG_PATH)


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
        merged: dict[str, list[str]] = {}
        for name, value in self.data.get("groups", {}).items():
            if isinstance(value, dict):
                targets = value.get("targets", [])
            else:
                targets = value
            merged[name] = list(targets)
        return merged

    @property
    def github(self) -> dict[str, Any]:
        return self.data.get("github", {})

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
    return subprocess.check_output(
        ["git", *args], cwd=cwd, text=True, timeout=GIT_TIMEOUT
    ).strip()


def git_try_output(args: list[str], cwd: Path) -> str | None:
    # A hung git (e.g. waiting on credentials) must not stall stamping; a
    # timeout is treated like any other failure here: fall back to None.
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=GIT_TIMEOUT,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


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
        # The build number is the commit count of each product's OWN repo
        # (config.repo_root), not this orchestration repo. This is deliberate:
        # ``local-sweep`` over several products yields a per-product build
        # number that tracks each product's history independently. To force a
        # single shared stamp across products, set CBUILD_BUILD_NUMBER (or the
        # product-prefixed <PREFIX>_BUILD_NUMBER) in the environment, which is
        # consumed by ``number_env`` above and short-circuits this git lookup.
        try:
            build = git_output(["rev-list", "--count", "HEAD"], config.repo_root)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
            build = os.getenv("GITHUB_RUN_NUMBER", "1")
    return Stamp(version, build)


def target_allowed_hosts(target: dict[str, Any]) -> set[str]:
    hosts = target.get("hosts") or target.get("host")
    if not hosts:
        return set()
    if isinstance(hosts, str):
        hosts = [hosts]
    return {HOST_ALIASES.get(str(host).lower(), str(host).lower()) for host in hosts}


def normalize_hosts(value: Any) -> list[str]:
    # Unset (None / empty) legitimately means "all hosts". But a NON-empty value
    # containing an unrecognized token is almost always a typo (e.g. "mcos" for
    # "macos"); raise instead of silently dropping it. The old code dropped
    # unknowns and, if that left nothing, fell back to all hosts — which masked
    # the mistake as "runs everywhere".
    if not value:
        return list(HOST_ORDER)
    hosts = [value] if isinstance(value, str) else list(value)
    normalized: list[str] = []
    unknown: list[str] = []
    for host in hosts:
        host_name = HOST_ALIASES.get(str(host).lower(), str(host).lower())
        if host_name == "any":
            for item in HOST_ORDER:
                if item not in normalized:
                    normalized.append(item)
        elif host_name in HOST_ORDER:
            if host_name not in normalized:
                normalized.append(host_name)
        else:
            unknown.append(str(host))
    if unknown:
        raise BuildError(
            f"Unknown host(s): {', '.join(unknown)}. "
            f"Valid hosts: {', '.join(HOST_ORDER)}, any."
        )
    return normalized


def string_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [str(item) for item in value]
    return []


def host_list(value: Any, host: str | None = None) -> list[str]:
    if isinstance(value, dict):
        host_name = host or current_host()
        return string_list(value.get(host_name) or value.get("default"))
    return string_list(value)
