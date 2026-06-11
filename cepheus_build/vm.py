"""VM pool lifecycle: ``cepheus-build vm up|down|status``.

Drives the dockur VM pool defined in ``docker/compose.yml`` and probes the SSH
endpoints the container backend dispatches into. The compose daemon usually
lives on a remote bare-metal Linux host (the only place with ``/dev/kvm``), so
compose commands run over ssh against a ``cepheus-build`` checkout there;
configure it under ``[container_profiles.<name>.compose]`` in ``build.toml``:

    [container_profiles.default.compose]
    host = "192.168.0.98"            # KVM host running the docker daemon
    user = "errai"
    dir  = "~/cepheus-build/docker"  # docker/ dir of a checkout on that host

With no ``compose`` table (or an empty ``host``) compose runs locally -- you
are on the KVM host itself.

``vm up --wait`` polls each VM's SSH endpoint until it accepts a connection or
the deadline passes: a freshly created VM spends a long time installing its OS
(watch the noVNC viewers, ports 8306/8406), while a stopped-but-installed VM
boots in minutes.
"""

from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import time
from pathlib import Path
from typing import Any, Callable

from .config import HOST_ORDER, TOOL_ROOT
from .container import (
    SSH_BATCH_OPTS,
    _posix_path,
    _ssh_base,
    container_profile_config,
    default_profile_name,
)
from .errors import BuildError
from .process import run_argv, style_prefix

# One ssh connection attempt per probe; the subprocess gets a little extra
# headroom so a wedged ssh cannot hang the wait loop.
PROBE_CONNECT_TIMEOUT = 5
PROBE_SUBPROCESS_TIMEOUT = 15

DEFAULT_COMPOSE_DIR = "~/cepheus-build/docker"


def compose_argv(
    compose_cfg: dict[str, Any], action_args: list[str]
) -> tuple[list[str], Path | None]:
    """argv (+ cwd for the local case) running ``docker compose <action_args>``.

    Remote (``host`` set): ``ssh user@host "cd <dir> && docker compose ..."``.
    The KVM host is Linux, so the remote command is POSIX-quoted. Local: plain
    ``docker compose`` with cwd = this checkout's ``docker/`` directory.
    """
    host = compose_cfg.get("host")
    if not host:
        return (["docker", "compose", *action_args], TOOL_ROOT / "docker")
    user = compose_cfg.get("user")
    for token in (str(host), str(user or "")):
        # A leading '-' would be parsed as an ssh OPTION, not a destination.
        if token.startswith("-"):
            raise BuildError(f"Invalid compose user/host '{token}' (must not start with '-').")
    destination = f"{user}@{host}" if user else str(host)
    port_opts = ["-p", str(compose_cfg["port"])] if compose_cfg.get("port") else []
    directory = str(compose_cfg.get("dir") or DEFAULT_COMPOSE_DIR)
    remote = (
        f"cd {_posix_path(directory)} && docker compose "
        + " ".join(shlex.quote(arg) for arg in action_args)
    )
    return (["ssh", *port_opts, *SSH_BATCH_OPTS, destination, remote], None)


def ssh_probe_argv(endpoint: dict[str, Any]) -> list[str]:
    """One non-interactive connection attempt against a VM's SSH endpoint.

    ``BatchMode=yes`` forbids password prompts (key auth is the contract);
    ``accept-new`` trusts a fresh VM's host key but still fails loudly if a
    known key CHANGES (e.g. after a VM reinstall -- clear known_hosts then).
    """
    destination, port_opts = _ssh_base(endpoint, host_override=None)
    return [
        "ssh",
        *port_opts,
        "-o",
        "BatchMode=yes",
        "-o",
        f"ConnectTimeout={PROBE_CONNECT_TIMEOUT}",
        "-o",
        "StrictHostKeyChecking=accept-new",
        destination,
        "exit 0",
    ]


def probe_endpoint(endpoint: dict[str, Any]) -> tuple[bool, str]:
    """(ready, reason): try one SSH connection to ``endpoint``."""
    argv = ssh_probe_argv(endpoint)
    try:
        result = subprocess.run(
            argv,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=PROBE_SUBPROCESS_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return (False, "ssh probe timed out")
    except FileNotFoundError:
        return (False, "ssh not found on PATH")
    if result.returncode == 0:
        return (True, "")
    reason = (result.stderr or "").strip().splitlines()
    return (False, reason[-1] if reason else f"ssh exited {result.returncode}")


def ssh_endpoints(profile: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """The profile's ``kind = "ssh"`` endpoints, keyed by host OS, HOST_ORDER."""
    found: dict[str, dict[str, Any]] = {}
    for host_os in HOST_ORDER:
        endpoint = profile.get(host_os)
        if isinstance(endpoint, dict) and str(endpoint.get("kind", "")).lower() == "ssh":
            found[host_os] = endpoint
    return found


def endpoint_label(endpoint: dict[str, Any]) -> str:
    destination, port_opts = _ssh_base(endpoint, host_override=None)
    port = f":{port_opts[1]}" if port_opts else ""
    return f"{destination}{port}"


def wait_for_ssh(
    endpoints: dict[str, dict[str, Any]],
    *,
    timeout: float,
    interval: float = 15.0,
    probe: Callable[[dict[str, Any]], tuple[bool, str]] = probe_endpoint,
    clock: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
) -> None:
    """Poll every endpoint until all accept SSH or ``timeout`` seconds pass."""
    pending = dict(endpoints)
    last_reason: dict[str, str] = {}
    start = clock()
    while pending:
        for host_os in list(pending):
            ready, reason = probe(pending[host_os])
            if ready:
                waited = int(clock() - start)
                print(f"{host_os}: ssh ready ({endpoint_label(pending[host_os])}, {waited}s)")
                del pending[host_os]
            else:
                last_reason[host_os] = reason
        if not pending:
            return
        elapsed = clock() - start
        if elapsed >= timeout:
            details = "; ".join(
                f"{host_os} ({endpoint_label(endpoint)}): "
                f"{last_reason.get(host_os) or 'no response'}"
                for host_os, endpoint in pending.items()
            )
            raise BuildError(
                f"VM SSH endpoint(s) not ready after {int(timeout)}s -- {details}. "
                "A fresh VM spends a long time installing its OS: watch the noVNC "
                "viewers (Windows :8306, macOS :8406) and re-run "
                "'cepheus-build vm up' when the install finishes."
            )
        remaining = int(timeout - elapsed)
        print(
            f"waiting for {', '.join(pending)} "
            f"(retry in {int(interval)}s, {remaining}s left)"
        )
        sleep(interval)


def cmd_vm(args: argparse.Namespace) -> int:
    profile_name = getattr(args, "container_profile", None) or default_profile_name()
    profile = container_profile_config(profile_name)
    compose_cfg = profile.get("compose")
    if compose_cfg is not None and not isinstance(compose_cfg, dict):
        raise BuildError(
            f"[container_profiles.{profile_name}.compose] must be a table."
        )
    compose_cfg = compose_cfg or {}
    endpoints = ssh_endpoints(profile)
    services = list(getattr(args, "services", None) or endpoints)
    dry_run = getattr(args, "dry_run", False)
    env = dict(os.environ)
    action = args.vm_action

    where = compose_cfg.get("host") or "local docker"
    print(
        f"{style_prefix('==>')} VM pool {action} "
        f"(profile '{profile_name}', compose on {where})"
    )

    if action == "up":
        argv, cwd = compose_argv(compose_cfg, ["up", "-d", *services])
        run_argv(argv, cwd or TOOL_ROOT, env, dry_run)
        wait_targets = {
            host_os: endpoint
            for host_os, endpoint in endpoints.items()
            if host_os in services
        }
        if getattr(args, "wait", True) and not dry_run and wait_targets:
            wait_for_ssh(wait_targets, timeout=getattr(args, "wait_timeout", 1200))
        return 0

    if action == "down":
        # `stop`, not `down`: the containers (and their port mappings/devices)
        # survive, only the VMs power off. VM disks live in named volumes
        # either way; `docker compose down` on the KVM host is the manual
        # escalation when a container itself must be recreated.
        argv, cwd = compose_argv(compose_cfg, ["stop", *services])
        run_argv(argv, cwd or TOOL_ROOT, env, dry_run)
        return 0

    if action == "status":
        argv, cwd = compose_argv(compose_cfg, ["ps", *services])
        run_argv(argv, cwd or TOOL_ROOT, env, dry_run)
        if dry_run:
            return 0
        failures = 0
        for host_os, endpoint in endpoints.items():
            if host_os not in services:
                continue
            ready, reason = probe_endpoint(endpoint)
            label = endpoint_label(endpoint)
            if ready:
                print(f"{host_os}: ssh ready ({label})")
            else:
                failures += 1
                print(f"{host_os}: ssh unreachable ({label}): {reason}")
        return 1 if failures else 0

    raise BuildError(f"Unknown vm action '{action}'.")
