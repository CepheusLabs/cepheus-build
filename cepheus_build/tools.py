"""Tool detection, prerequisite checks, and dependency installation."""

from __future__ import annotations

import os
import shutil
import subprocess
from typing import Any

from .config import (
    TOOL_ROOT,
    VIRTUAL_TOOLS,
    ProductConfig,
    current_host,
    host_list,
    load_tool_config,
    string_list,
    target_allowed_hosts,
)
from .errors import BuildError
from .process import augment_process_path, run_command

# Tool version/check probes should answer quickly; a hung probe must not stall
# ``doctor``/``build``. Treated as a check failure on expiry.
TOOL_CHECK_TIMEOUT = 60


def ensure_host(target_name: str, target: dict[str, Any], skip_unsupported: bool) -> bool:
    allowed = target_allowed_hosts(target)
    if not allowed:
        return True
    host = current_host()
    if host in allowed or "any" in allowed:
        return True
    message = f"Target '{target_name}' requires {', '.join(sorted(allowed))}; current host is {host}."
    if skip_unsupported:
        print(f"skip: {message}")
        return False
    raise BuildError(message)


def tool_status(tool: str) -> tuple[bool, str]:
    if tool in VIRTUAL_TOOLS:
        return True, "managed by product command/workflow setup"
    config = tool_config(tool)
    check_commands = host_list(config.get("check"))
    if check_commands:
        try:
            result = subprocess.run(
                check_commands[0],
                shell=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=TOOL_CHECK_TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            return False, "check timed out"
        if result.returncode != 0:
            hint = str(config.get("hint") or "")
            detail = result.stderr.strip() or result.stdout.strip() or "check failed"
            if hint:
                detail = f"{detail} ({hint})"
            return False, detail
        path = shutil.which(str(config.get("binary") or tool))
        return True, path or "ok"

    path = shutil.which(str(config.get("binary") or tool))
    if path:
        return True, path
    hint = str(config.get("hint") or "")
    detail = "missing"
    if hint:
        detail = f"{detail} ({hint})"
    return False, detail


def tool_install_commands(tool: str) -> list[str]:
    install = tool_config(tool).get("install")
    if isinstance(install, dict):
        host = current_host()
        return string_list(install.get(host) or install.get("default"))
    return string_list(install)


def collect_target_tools(
    config: ProductConfig,
    target_names: list[str],
    skip_unsupported: bool,
) -> set[str]:
    tools = set(config.data.get("tools", {}).get("required", []) or [])
    for target_name in target_names:
        target = config.target(target_name)
        if not ensure_host(target_name, target, skip_unsupported=skip_unsupported):
            continue
        tools.update(host_list(target.get("tools")))
    return tools


def install_deps_for_targets(
    config: ProductConfig,
    target_names: list[str],
    *,
    dry_run: bool,
    skip_existing: bool,
    skip_unsupported: bool,
    quiet_existing: bool = False,
    quiet_empty: bool = False,
) -> int:
    tools = collect_target_tools(config, target_names, skip_unsupported)
    if not tools:
        if not quiet_empty:
            print("No tools declared for selected targets.")
        return 0

    missing_manual: list[str] = []
    for tool in sorted(tools):
        ok, detail = tool_status(tool)
        if ok and skip_existing:
            if not quiet_existing:
                print(f"ok: {tool}: {detail}")
            continue

        commands = tool_install_commands(tool)
        if not commands:
            if ok:
                print(f"manual: {tool}: no installer configured; already present at {detail}")
            else:
                print(f"manual: {tool}: {detail}")
                missing_manual.append(tool)
            continue

        print(f"install: {tool}")
        for command in commands:
            run_command(command, TOOL_ROOT, dict(os.environ), dry_run)
            augment_process_path()

    if missing_manual:
        raise BuildError(
            "No installer configured for missing tools: "
            + ", ".join(missing_manual)
            + ". Add [tools.<name>].install to build.toml or install them manually."
        )
    return 0


def require_target_tools(config: ProductConfig, target_name: str, target: dict[str, Any]) -> None:
    tools = set(config.data.get("tools", {}).get("required", []) or [])
    tools.update(host_list(target.get("tools")))
    missing: list[str] = []
    for tool in sorted(tools):
        ok, detail = tool_status(tool)
        if not ok:
            missing.append(f"{tool}: {detail}")
    if missing:
        details = "\n  ".join(missing)
        raise BuildError(
            f"Missing required tools for {config.slug} target '{target_name}':\n  {details}"
        )


def tools_config() -> dict[str, Any]:
    return load_tool_config().get("tools", {})


def tool_config(tool: str) -> dict[str, Any]:
    config = tools_config().get(tool, {})
    return config if isinstance(config, dict) else {}
