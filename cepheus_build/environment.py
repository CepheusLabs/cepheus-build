"""Environment variable resolution and interpolation for build commands."""

from __future__ import annotations

import os
import re
from typing import Any

from .config import HOST_ORDER, TOOL_ROOT, ProductConfig, Stamp, current_host


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


def build_env(
    config: ProductConfig,
    stamp: Stamp,
    extra_env: dict[str, str] | None = None,
) -> dict[str, str]:
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
    if extra_env:
        env.update({key: value for key, value in extra_env.items() if value})
    return env


def expand_env_refs(value: str, env: dict[str, str]) -> str:
    def replace(match: re.Match[str]) -> str:
        name = match.group(1) or match.group(2) or ""
        return env.get(name, match.group(0))

    return re.sub(r"\$([A-Za-z_][A-Za-z0-9_]*)|\$\{([^}]+)\}", replace, value)


def target_env_values(target: dict[str, Any], env: dict[str, str]) -> dict[str, str]:
    raw = target.get("env")
    if not isinstance(raw, dict):
        return {}

    selected: dict[str, Any]
    host = current_host()
    if any(key in raw for key in [*HOST_ORDER, "default"]):
        selected = {}
        default_env = raw.get("default")
        host_env = raw.get(host)
        if isinstance(default_env, dict):
            selected.update(default_env)
        if isinstance(host_env, dict):
            selected.update(host_env)
    else:
        selected = raw

    resolved: dict[str, str] = {}
    for key, value in selected.items():
        resolved[str(key)] = expand_env_refs(resolve_value(value, env), env)
    return resolved
