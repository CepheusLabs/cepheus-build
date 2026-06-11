"""Container / VM execution backend: build any OS target from any host.

This is the third execution mode (peer of ``local`` and ``github``). Instead of
running a target on the current host or dispatching a GitHub workflow, it routes
each target into a container or VM of the target's *required* OS and re-invokes
the **same** ``cepheus-build`` there with ``--execution-mode local``.

The key property: inside the matching OS, :func:`cepheus_build.config.current_host`
already returns the right value, so host gating, version stamping, tool checks,
and artifact globbing all work unchanged. This module only provides transport:

* ``kind = "docker"`` (Linux): ``docker run`` a build image with the product repo
  bind-mounted and this toolkit mounted read-only. Artifacts land in the bind
  mount, so they are already on the host afterwards.
* ``kind = "ssh"`` (Windows / macOS): ``rsync`` the repo into a dockur KVM VM,
  ``ssh`` the build, then ``rsync`` the ``build/`` tree back so the existing
  ``artifacts`` step finds the outputs.

Endpoints come from ``[container_profiles.<name>]`` in ``build.toml``. See
``docs/cross-os-builds.md`` and ``docker/compose.yml`` for the VM pool.

Trust boundary: the dispatched ``cepheus-build`` runs the product TOML's trusted
shell commands inside the container/VM. SSH targets execute those commands on a
remote VM, so the VMs must only be reachable with credentials you control
(key-based auth). This is the same trust model as the existing ``local`` mode.

Dependency resolution: container/VM builds resolve first-party dependencies from
the **committed pins** (forge git ref, Go pseudo-versions) exactly like CI — the
ignored local ``deps --write`` overrides (``pubspec_overrides.yaml`` / ``go.work``)
are bypassed (``GOWORK=off`` for Go; excluded from the rsync for SSH; warned about
for a bind-mounted Flutter tree).
"""

from __future__ import annotations

import argparse
import os
import shlex
import subprocess
from pathlib import Path
from typing import Any

from .config import (
    HOST_ORDER,
    TOOL_ROOT,
    ProductConfig,
    Stamp,
    compute_stamp,
    load_tool_config,
)
from .errors import BuildError
from .github import preferred_host_for_target
from .process import display_command, run_command, style_prefix

# The host-relative subtree that holds every build output. One rsync of this
# directory brings all of a host's target artifacts back from an SSH VM.
ARTIFACT_DIR = "build"

# Files that exist only for local sibling-checkout development. Container/VM
# builds use committed pins instead, so these are never shipped into the build
# environment. ``.dart_tool`` / ``build`` are large, host-specific caches.
RSYNC_EXCLUDES = [
    ".git/",
    "build/",
    ".dart_tool/",
    "pubspec_overrides.yaml",
    "go.work",
    "go.work.sum",
]

# Where this toolkit is mounted inside a Linux build container (read-only).
TOOLKIT_MOUNT = "/opt/cepheus-build"

# Default in-container working directory (the bind-mounted product repo).
DEFAULT_WORKDIR = "/work"


# ---------------------------------------------------------------------------
# Profile lookup (mirrors github.runner_profile_* helpers)
# ---------------------------------------------------------------------------


def container_profiles() -> dict[str, Any]:
    return load_tool_config().get("container_profiles", {})


def container_profile_names() -> list[str]:
    return sorted(container_profiles())


def container_profile_config(profile: str) -> dict[str, Any]:
    profiles = container_profiles()
    profile_config = profiles.get(profile)
    if not isinstance(profile_config, dict):
        known = ", ".join(sorted(profiles)) or "none"
        raise BuildError(
            f"Unknown container profile '{profile}'. Known profiles: {known}. "
            "Define one under [container_profiles.<name>] in build.toml."
        )
    return profile_config


def host_endpoint(profile_config: dict[str, Any], host: str) -> dict[str, Any]:
    endpoint = profile_config.get(host)
    if not isinstance(endpoint, dict):
        label = profile_config.get("label") or "container profile"
        raise BuildError(
            f"{label} has no '{host}' endpoint. Add a [container_profiles."
            f"<name>.{host}] table (kind = \"docker\" or \"ssh\")."
        )
    return endpoint


def default_profile_name() -> str:
    names = container_profile_names()
    if not names:
        raise BuildError(
            "No container profiles configured. Add [container_profiles.<name>] "
            "to build.toml (see docs/cross-os-builds.md)."
        )
    return names[0]


# ---------------------------------------------------------------------------
# Shared, OS-independent argv builders (unit-tested directly)
# ---------------------------------------------------------------------------


def env_passthrough_names(config: ProductConfig) -> list[str]:
    """Env var names a build cares about: those referenced by dart_defines.

    Flutter ``dart_defines`` are declared as ``{ env = "NAME", default = ... }``
    in the product TOML. Forwarding the named vars (when set on the dispatch
    host) lets a container/VM build pick up API endpoints/secrets the same way a
    local build would, while unset ones fall back to their declared default.
    """
    names: list[str] = []
    defines = config.flutter.get("dart_defines")
    if isinstance(defines, dict):
        for spec in defines.values():
            if isinstance(spec, dict):
                name = spec.get("env")
                if name and str(name) not in names:
                    names.append(str(name))
    return names


def container_env_pairs(config: ProductConfig, stamp: Stamp) -> list[tuple[str, str]]:
    """(name, value) env pairs to inject into the container/VM build.

    Always carries the version stamp computed on the dispatch host (where the
    product's ``.git`` is intact) so the inner build reuses the *same* stamp
    instead of recomputing a different build number from an SSH-synced tree that
    excludes ``.git``. Adds any set dart_define env vars.
    """
    pairs: list[tuple[str, str]] = [
        ("CBUILD_VERSION", stamp.version),
        ("CBUILD_BUILD_NUMBER", stamp.build_number),
    ]
    for name in env_passthrough_names(config):
        value = os.environ.get(name)
        if value:
            pairs.append((name, value))
    return pairs


def build_subcommand_args(
    config: ProductConfig,
    targets: list[str],
    args: argparse.Namespace,
    *,
    repo_root: str,
) -> list[str]:
    """The ``build ...`` argv (without the launcher) run inside the container/VM.

    Always ``--execution-mode local --no-sync``: the transport already placed the
    code, so the inner process must not recurse into another container nor re-pull.
    """
    argv = [
        "build",
        "-p",
        config.slug,
        *targets,
        "--repo-root",
        repo_root,
        "--execution-mode",
        "local",
        "--no-sync",
        "--mode",
        getattr(args, "mode", "release"),
    ]
    if not getattr(args, "check_tools", True):
        argv.append("--no-check-tools")
    argv.append("--keep-going" if getattr(args, "keep_going", True) else "--no-keep-going")
    for flutter_arg in getattr(args, "flutter_arg", None) or []:
        argv.extend(["--flutter-arg", flutter_arg])
    return argv


def inner_argv(
    config: ProductConfig,
    targets: list[str],
    args: argparse.Namespace,
    *,
    repo_root: str,
    launcher: str,
) -> list[str]:
    """Full in-environment argv: ``launcher`` tokens + the build subcommand.

    ``launcher`` is how the CLI is invoked inside the environment, e.g.
    ``/opt/cepheus-build/bin/cepheus-build`` (Linux container). Used by the docker
    path, where ``display_command`` quotes for the local shell.
    """
    return [
        *shlex.split(launcher),
        *build_subcommand_args(config, targets, args, repo_root=repo_root),
    ]


def docker_argv(
    config: ProductConfig,
    targets: list[str],
    endpoint: dict[str, Any],
    stamp: Stamp,
    args: argparse.Namespace,
    *,
    docker_host: str | None = None,
) -> list[str]:
    """Full ``docker run`` argv for a Linux build container."""
    image = endpoint.get("image")
    if not image:
        raise BuildError("Linux container endpoint is missing 'image' in build.toml.")
    workdir = str(endpoint.get("workdir") or DEFAULT_WORKDIR)
    launcher = str(endpoint.get("launcher") or f"{TOOLKIT_MOUNT}/bin/cepheus-build")
    host = docker_host or endpoint.get("host")

    argv: list[str] = ["docker"]
    if host:
        argv += ["--host", str(host)]
    argv += [
        "run",
        "--rm",
        "-v",
        f"{config.repo_root}:{workdir}",
        "-v",
        f"{TOOL_ROOT}:{TOOLKIT_MOUNT}:ro",
        "-w",
        workdir,
        "-e",
        "GOWORK=off",
    ]
    for name, value in container_env_pairs(config, stamp):
        argv += ["-e", f"{name}={value}"]
    for extra in endpoint.get("run_args") or []:
        argv.append(str(extra))
    argv.append(str(image))
    argv += inner_argv(config, targets, args, repo_root=workdir, launcher=launcher)
    return argv


def _ssh_base(endpoint: dict[str, Any], *, host_override: str | None) -> tuple[str, list[str]]:
    """Return ``user@host`` plus the shared ``-p PORT`` option list for ssh/rsync."""
    user = endpoint.get("user")
    host = host_override or endpoint.get("host")
    if not user or not host:
        raise BuildError("SSH container endpoint needs both 'user' and 'host' in build.toml.")
    port_opts: list[str] = []
    port = endpoint.get("port")
    if port:
        port_opts = ["-p", str(port)]
    return f"{user}@{host}", port_opts


def _remote_repo(endpoint: dict[str, Any], slug: str) -> str:
    remote_root = str(endpoint.get("remote_root") or "~/cbuild")
    return f"{remote_root.rstrip('/')}/{slug}"


def _default_launcher(host_os: str, endpoint: dict[str, Any]) -> str:
    if endpoint.get("launcher"):
        return str(endpoint["launcher"])
    toolkit = str(endpoint.get("toolkit") or "~/cepheus-build")
    if host_os == "windows":
        # The CLI is a Python script; on Windows it is invoked via the interpreter.
        return f"python {toolkit}/bin/cepheus-build"
    return f"{toolkit}/bin/cepheus-build"


def _remote_shell(host_os: str, endpoint: dict[str, Any]) -> str:
    shell = endpoint.get("shell")
    if shell:
        return str(shell)
    return "powershell" if host_os == "windows" else "posix"


def remote_command(
    shell: str,
    remote_repo: str,
    env_pairs: list[tuple[str, str]],
    launcher: str,
    build_args: list[str],
) -> str:
    """Build the single command string handed to the remote shell over ssh.

    ``posix`` →  ``cd <repo> && NAME='v' ... <launcher> build ...`` (POSIX quoting).
    ``powershell`` → ``cd <repo>; $env:NAME='v'; & <launcher> build ...`` (the ``&``
    call operator is required to invoke a path/quoted command in PowerShell).
    A leading ``~/`` is expanded to the remote home (``$HOME`` / ``$env:USERPROFILE``)
    rather than quoted, since a quoted ``~`` would not expand. The result is passed
    as one argument to ``ssh``; local-shell quoting is applied by
    :func:`display_command`.
    """
    launcher_tokens = shlex.split(launcher)
    if shell == "powershell":
        parts = [f"cd {_ps_path(remote_repo)}"]
        parts += [f"$env:{name} = {_ps_quote(value)}" for name, value in env_pairs]
        invocation = ["&", *(_ps_path(tok) for tok in launcher_tokens)]
        invocation += [_ps_quote(arg) for arg in build_args]
        parts.append(" ".join(invocation))
        return "; ".join(parts)

    assignments = " ".join(f"{name}={shlex.quote(value)}" for name, value in env_pairs)
    launcher_part = " ".join(_posix_path(tok) for tok in launcher_tokens)
    args_part = " ".join(shlex.quote(arg) for arg in build_args)
    prefix = f"{assignments} " if assignments else ""
    return f"cd {_posix_path(remote_repo)} && {prefix}{launcher_part} {args_part}"


def _posix_path(value: str) -> str:
    """Shell-safe POSIX path with a leading ``~/`` expanded to ``$HOME``."""
    if value == "~":
        return '"$HOME"'
    if value.startswith("~/"):
        return '"$HOME"/' + shlex.quote(value[2:])
    return shlex.quote(value)


def _ps_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def _ps_path(value: str) -> str:
    """PowerShell path with a leading ``~/`` expanded to ``$env:USERPROFILE``.

    A literal ``~`` is only resolved by PowerShell providers (Set-Location), not
    when passed as an argument to an external exe, so expand it explicitly.
    """
    if value == "~":
        return '"$env:USERPROFILE"'
    if value.startswith("~/"):
        return '"$env:USERPROFILE/' + value[2:].replace('"', '`"') + '"'
    return _ps_quote(value)


def _as_posix_dir(repo_root: Path) -> str:
    """``repo_root`` as a forward-slash path with no trailing separator.

    rsync wants POSIX-style sources even on Windows (it runs under Git-Bash/MSYS);
    a trailing slash on the source means "copy the contents into the destination".
    """
    return repo_root.as_posix().rstrip("/")


def rsync_push_argv(repo_root: Path, destination: str, port_opts: list[str]) -> list[str]:
    ssh_cmd = " ".join(["ssh", *port_opts])
    argv = ["rsync", "-az", "--delete", "-e", ssh_cmd]
    for pattern in RSYNC_EXCLUDES:
        argv += ["--exclude", pattern]
    # Trailing slash on the source copies the contents into the destination dir.
    argv += [f"{_as_posix_dir(repo_root)}/", f"{destination}/"]
    return argv


def rsync_pull_argv(source: str, repo_root: Path, port_opts: list[str]) -> list[str]:
    ssh_cmd = " ".join(["ssh", *port_opts])
    local = f"{_as_posix_dir(repo_root)}/{ARTIFACT_DIR}/"
    return ["rsync", "-az", "-e", ssh_cmd, f"{source}/{ARTIFACT_DIR}/", local]


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------


def group_targets_by_host(config: ProductConfig, targets: list[str]) -> dict[str, list[str]]:
    """Bucket targets by the OS they must build on, preserving HOST_ORDER.

    Reuses :func:`cepheus_build.github.preferred_host_for_target`, the same logic
    the CI matrix uses, so container routing and CI routing agree.
    """
    grouped: dict[str, list[str]] = {}
    for target_name in targets:
        target = config.target(target_name)
        host = preferred_host_for_target(target_name, target)
        if host is None:
            print(f"skip: {target_name} declares no buildable host")
            continue
        grouped.setdefault(host, []).append(target_name)
    return {host: grouped[host] for host in HOST_ORDER if host in grouped}


def _warn_local_overrides(repo_root: Path) -> None:
    overrides = [
        name
        for name in ("pubspec_overrides.yaml", "go.work")
        if (repo_root / name).exists()
    ]
    if overrides:
        joined = ", ".join(overrides)
        print(
            f"warning: {joined} present in {repo_root}; container/VM builds use "
            "committed pins (GOWORK=off bypasses go.work; remove pubspec_overrides.yaml "
            "for a clean Flutter build)."
        )


def run_docker_target(
    config: ProductConfig,
    targets: list[str],
    endpoint: dict[str, Any],
    stamp: Stamp,
    args: argparse.Namespace,
) -> None:
    _warn_local_overrides(config.repo_root)
    argv = docker_argv(
        config,
        targets,
        endpoint,
        stamp,
        args,
        docker_host=getattr(args, "container_host", None),
    )
    command = display_command(argv[0], argv[1:])
    run_command(
        command,
        TOOL_ROOT,
        dict(os.environ),
        getattr(args, "dry_run", False),
        expand_vars=False,
    )


def run_ssh_target(
    config: ProductConfig,
    host_os: str,
    targets: list[str],
    endpoint: dict[str, Any],
    stamp: Stamp,
    args: argparse.Namespace,
) -> None:
    dry_run = getattr(args, "dry_run", False)
    destination, port_opts = _ssh_base(
        endpoint, host_override=getattr(args, "container_host", None)
    )
    remote_repo = _remote_repo(endpoint, config.slug)
    launcher = _default_launcher(host_os, endpoint)
    shell = _remote_shell(host_os, endpoint)
    env = dict(os.environ)

    # 1. Push a clean copy of the repo (committed-pins; overrides excluded).
    push = rsync_push_argv(config.repo_root, f"{destination}:{remote_repo}", port_opts)
    run_command(display_command(push[0], push[1:]), TOOL_ROOT, env, dry_run, expand_vars=False)

    # 2. Run the build inside the VM.
    sub_args = build_subcommand_args(config, targets, args, repo_root=".")
    remote = remote_command(
        shell, remote_repo, container_env_pairs(config, stamp), launcher, sub_args
    )
    ssh_args = [*port_opts, destination, remote]
    run_command(display_command("ssh", ssh_args), TOOL_ROOT, env, dry_run, expand_vars=False)

    # 3. Pull the build outputs back so `artifacts` finds them on the host.
    pull = rsync_pull_argv(f"{destination}:{remote_repo}", config.repo_root, port_opts)
    run_command(display_command(pull[0], pull[1:]), TOOL_ROOT, env, dry_run, expand_vars=False)


def cmd_container_build(config: ProductConfig, args: argparse.Namespace) -> int:
    profile_name = getattr(args, "container_profile", None) or default_profile_name()
    profile = container_profile_config(profile_name)
    targets = config.expand_targets(getattr(args, "targets", None) or ["desktop"])
    stamp = compute_stamp(config)
    grouped = group_targets_by_host(config, targets)
    if not grouped:
        raise BuildError("No targets could be routed to a container/VM host.")

    print(
        f"{style_prefix('==>')} {config.display_name}: container build "
        f"({stamp.full}) via profile '{profile_name}'"
    )

    failures: list[tuple[str, str]] = []
    for host_os, host_targets in grouped.items():
        endpoint = host_endpoint(profile, host_os)
        kind = str(endpoint.get("kind") or "").lower()
        label = " ".join(host_targets)
        try:
            if kind == "docker":
                run_docker_target(config, host_targets, endpoint, stamp, args)
            elif kind == "ssh":
                run_ssh_target(config, host_os, host_targets, endpoint, stamp, args)
            else:
                raise BuildError(
                    f"container profile '{profile_name}' {host_os} endpoint has "
                    f"unknown kind '{kind}' (expected 'docker' or 'ssh')."
                )
        except (BuildError, subprocess.CalledProcessError) as exc:
            message = (
                f"command failed with exit code {exc.returncode}"
                if isinstance(exc, subprocess.CalledProcessError)
                else str(exc)
            )
            failures.append((f"{host_os}: {label}", message))
            print(f"failed: {host_os} ({label}): {message}")
            if not getattr(args, "keep_going", True):
                break

    if failures:
        print("\n## Container build summary")
        for where, message in failures:
            print(f"failed: {where}: {message}")
        return 1
    return 0
