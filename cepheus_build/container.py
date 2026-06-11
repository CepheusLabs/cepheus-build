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
  ``ssh`` the build, then ``rsync`` the targets' declared artifact paths back
  so the existing ``artifacts`` step finds the outputs.

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
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor
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
from .process import locked_print, run_argv, style_prefix, terminate_active_processes
from .tools import tool_status

# Characters that make a path segment a glob pattern rather than a literal.
_GLOB_CHARS = frozenset("*?[")

# Files that exist only for local sibling-checkout development. Container/VM
# builds use committed pins instead, so these are never shipped into the build
# environment. ``build``/``.dart_tool``/``target``/``dist`` are large,
# host-specific output/cache trees the remote build regenerates from source --
# excluding them also keeps the push from racing a concurrent local docker
# build's bind-mount writes in parallel dispatch (dir patterns with no leading
# slash match at any depth, covering app/build, packaging/*/dist, etc.).
RSYNC_EXCLUDES = [
    ".git/",
    "build/",
    ".dart_tool/",
    "target/",
    "dist/",
    "pubspec_overrides.yaml",
    "go.work",
    "go.work.sum",
]

# Non-interactive SSH for every transport command: no password prompts (key
# auth is the contract -- a prompt would hang the GUI / parallel dispatch),
# and trust-on-first-use host keys (a fresh VM is unknown; a CHANGED key
# still fails loudly -- clear known_hosts after a VM reinstall).
SSH_BATCH_OPTS = [
    "-o",
    "BatchMode=yes",
    "-o",
    "StrictHostKeyChecking=accept-new",
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


# Env vars forwarded into every container/VM build when set on the dispatch
# host, beyond the product's declared dart_defines. CEPHEUS_READ_TOKEN feeds
# build_env's ephemeral git auth inside the environment (private first-party
# git pins resolve during pub get / go mod / cargo). Treated as a secret:
# docker passes it name-only, the ssh echo redacts it.
EXTRA_ENV_PASSTHROUGH = ["CEPHEUS_READ_TOKEN"]


def container_env_pairs(config: ProductConfig, stamp: Stamp) -> list[tuple[str, str]]:
    """(name, value) env pairs to inject into the container/VM build.

    Always carries the version stamp computed on the dispatch host (where the
    product's ``.git`` is intact) so the inner build reuses the *same* stamp
    instead of recomputing a different build number from an SSH-synced tree that
    excludes ``.git``. Adds any set dart_define env vars and the extra
    passthrough secrets.
    """
    pairs: list[tuple[str, str]] = [
        ("CBUILD_VERSION", stamp.version),
        ("CBUILD_BUILD_NUMBER", stamp.build_number),
    ]
    for name in (*env_passthrough_names(config), *EXTRA_ENV_PASSTHROUGH):
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
) -> list[str]:
    """Full ``docker run`` argv for a Linux build container.

    The docker engine must be LOCAL: the run bind-mounts the dispatch host's
    repo and toolkit, and a remote engine (``docker --host``) would resolve
    those paths on ITS filesystem -- silently building the wrong tree (or
    nothing) with the artifacts stranded on the remote machine. Routing a
    Linux build to another machine is what ``kind = "ssh"`` is for.
    """
    image = endpoint.get("image")
    if not image:
        raise BuildError("Linux container endpoint is missing 'image' in build.toml.")
    workdir = str(endpoint.get("workdir") or DEFAULT_WORKDIR)
    launcher = str(endpoint.get("launcher") or f"{TOOLKIT_MOUNT}/bin/cepheus-build")
    host = endpoint.get("host")
    if host:
        raise BuildError(
            "A docker endpoint cannot target a remote engine: the build "
            "bind-mounts dispatch-host paths, which do not exist on "
            f"'{host}'. Use kind = \"ssh\" to build on another machine "
            "(--container-host only overrides ssh endpoints)."
        )

    argv: list[str] = [
        "docker",
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
    # Stamp values are not secret and ride inline; forwarded dart_define env
    # vars and passthrough secrets use the name-only ``-e NAME`` form so their
    # VALUES never appear in the echoed command or logs -- docker reads them
    # from the client process environment (run_docker_target passes os.environ
    # to run_argv).
    argv += ["-e", f"CBUILD_VERSION={stamp.version}"]
    argv += ["-e", f"CBUILD_BUILD_NUMBER={stamp.build_number}"]
    for name in (*env_passthrough_names(config), *EXTRA_ENV_PASSTHROUGH):
        if os.environ.get(name):
            argv += ["-e", name]
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
    for token in (str(user), str(host)):
        # A leading '-' would be parsed as an ssh/rsync OPTION, not a
        # destination (argv injection through config values).
        if token.startswith("-"):
            raise BuildError(f"Invalid ssh user/host '{token}' (must not start with '-').")
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


# The only remote shells this backend can synthesize commands for. Fail closed
# on anything else: a typo'd ``shell = "powershel"`` silently quoted as POSIX
# would produce a subtly broken remote command instead of a clear error.
VALID_REMOTE_SHELLS = ("posix", "powershell")


def _remote_shell(host_os: str, endpoint: dict[str, Any]) -> str:
    shell = str(endpoint.get("shell") or ("powershell" if host_os == "windows" else "posix"))
    if shell not in VALID_REMOTE_SHELLS:
        raise BuildError(
            f"Unknown remote shell '{shell}' (expected one of: "
            f"{', '.join(VALID_REMOTE_SHELLS)})."
        )
    return shell


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
    if shell == "powershell":
        # PowerShell joins statements with ';' regardless of failure ('&&' is
        # a parse error in Windows PowerShell 5.1), so make errors terminating:
        # with $ErrorActionPreference = 'Stop' a failed cd aborts instead of
        # running the build in the wrong directory. Backslashes in a configured
        # launcher are normalized to forward slashes (PowerShell accepts them);
        # shlex.split would otherwise eat them as escapes.
        launcher_tokens = shlex.split(launcher.replace("\\", "/"))
        parts = ["$ErrorActionPreference = 'Stop'", f"cd {_ps_path(remote_repo)}"]
        parts += [f"$env:{name} = {_ps_quote(value)}" for name, value in env_pairs]
        invocation = ["&", *(_ps_path(tok) for tok in launcher_tokens)]
        invocation += [_ps_quote(arg) for arg in build_args]
        parts.append(" ".join(invocation))
        return "; ".join(parts)
    if shell != "posix":
        raise BuildError(
            f"Unknown remote shell '{shell}' (expected one of: "
            f"{', '.join(VALID_REMOTE_SHELLS)})."
        )
    launcher_tokens = shlex.split(launcher)

    assignments = " ".join(f"{name}={shlex.quote(value)}" for name, value in env_pairs)
    launcher_part = " ".join(_posix_path(tok) for tok in launcher_tokens)
    args_part = " ".join(shlex.quote(arg) for arg in build_args)
    prefix = f"{assignments} " if assignments else ""
    return f"cd {_posix_path(remote_repo)} && {prefix}{launcher_part} {args_part}"


def remote_prepare_command(shell: str, remote_repo: str, roots: list[str]) -> str:
    """Command that prepares ``remote_repo`` on the VM before the push.

    Two jobs, both idempotent: create the repo dir (rsync does not ``mkdir -p``
    its destination, so the very first push to a fresh VM would fail;
    ``--mkpath`` is avoided because the macOS VM may carry the ancient stock
    rsync), and delete the declared artifact ``roots`` from any previous build
    (they are excluded from the push's ``--delete``, so without this a stale
    version-stamped DMG/EXE from an older run would ride back on the pull and
    satisfy the host-side artifact globs).
    """
    if shell == "powershell":
        parts = [
            f"New-Item -ItemType Directory -Force -Path {_ps_path(remote_repo)} "
            "| Out-Null"
        ]
        parts += [
            "Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "
            f"-LiteralPath {_ps_path(f'{remote_repo}/{root}')}"
            for root in roots
        ]
        return "; ".join(parts)
    if shell != "posix":
        raise BuildError(
            f"Unknown remote shell '{shell}' (expected one of: "
            f"{', '.join(VALID_REMOTE_SHELLS)})."
        )
    command = f"mkdir -p {_posix_path(remote_repo)}"
    if roots:
        targets = " ".join(_posix_path(f"{remote_repo}/{root}") for root in roots)
        command += f" && rm -rf {targets}"
    return command


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
    when passed as an argument to an external exe, so expand it explicitly. The
    tail rides inside the double-quoted string, so every character PowerShell
    expands there (backtick, double quote, ``$``) is escaped -- only the
    intended ``$env:USERPROFILE`` may interpolate.
    """
    if value == "~":
        return '"$env:USERPROFILE"'
    if value.startswith("~/"):
        tail = (
            value[2:]
            .replace("`", "``")
            .replace('"', '`"')
            .replace("$", "`$")
        )
        return f'"$env:USERPROFILE/{tail}"'
    return _ps_quote(value)


def _glob_free_root(artifact: str) -> str | None:
    """Longest leading path of ``artifact`` that contains no glob characters.

    ``build/macos/printdeck-*-macos.dmg`` → ``build/macos``; a fully literal
    path (file or directory) is returned whole. ``None`` when the very first
    segment is globbed -- there is nothing safe to anchor a pull on.
    """
    parts = [p for p in artifact.replace("\\", "/").split("/") if p and p != "."]
    clean: list[str] = []
    for part in parts:
        if _GLOB_CHARS.intersection(part):
            break
        clean.append(part)
    if not clean:
        return None
    return "/".join(clean)


def artifact_pull_roots(
    config: ProductConfig, targets: list[str], *, prefix: str = ""
) -> list[str]:
    """Repo-relative paths to rsync back from an SSH VM after a build.

    Derived from each target's declared ``artifacts`` globs (the same source
    of truth the ``artifacts`` subcommand resolves), so DMGs under ``dist/``,
    installers under ``packaging/*/dist/``, and Rust binaries under
    ``target/`` all come home -- not just the Flutter ``build/`` tree. Roots
    nested inside another root collapse into the ancestor.
    """
    roots: list[str] = []
    for target_name in targets:
        target = config.target(target_name)
        artifacts = [str(item) for item in (target.get("artifacts") or [])]
        if not artifacts:
            locked_print(
                f"{prefix}warning: target '{target_name}' declares no artifacts; "
                "nothing will be pulled back from the VM for it."
            )
            continue
        for artifact in artifacts:
            normalized = artifact.replace("\\", "/")
            if normalized.startswith("/") or (len(normalized) > 1 and normalized[1] == ":"):
                locked_print(
                    f"{prefix}warning: artifact '{artifact}' is absolute; only "
                    "repo-relative artifacts are pulled back from a VM."
                )
                continue
            root = _glob_free_root(normalized)
            if root is None:
                locked_print(
                    f"{prefix}warning: artifact '{artifact}' globs its first path "
                    "segment; cannot derive a pull root for it."
                )
                continue
            if root not in roots:
                roots.append(root)
    return sorted(
        root
        for root in roots
        if not any(other != root and root.startswith(f"{other}/") for other in roots)
    )


def _rsync_remote_path(remote_repo: str) -> str:
    """``remote_repo`` as an rsync remote path: relative to the remote home.

    rsync resolves a relative remote path against the remote user's home
    directory, so a leading ``~/`` is dropped rather than relied on for shell
    expansion. Absolute paths pass through unchanged.
    """
    if remote_repo == "~":
        return "."
    if remote_repo.startswith("~/"):
        return remote_repo[2:]
    return remote_repo


def _sibling_ssh() -> str | None:
    """An ssh.exe living NEXT TO the resolved rsync binary, if any (Windows).

    A Cygwin/MSYS rsync cannot drive the native Win32-OpenSSH ssh.exe
    (incompatible pipe handling), but every Windows rsync distribution
    (cwRsync, MSYS2) ships a matching ssh in the same directory -- prefer it
    automatically so dispatch hosts need no per-machine config.
    """
    if os.name != "nt":
        return None
    rsync_path = shutil.which("rsync")
    if not rsync_path:
        return None
    candidate = Path(rsync_path).parent / "ssh.exe"
    if candidate.exists():
        return candidate.as_posix()
    return None


def _rsync_transport(endpoint: dict[str, Any], port_opts: list[str]) -> str:
    """The ``-e`` remote-shell string for rsync (ssh + port + batch options).

    The ssh binary rsync spawns is, in order: the endpoint's ``rsync_ssh``
    pin, the ssh.exe co-located with rsync on Windows (see
    :func:`_sibling_ssh`), else plain ``ssh`` from PATH.
    """
    ssh_program = str(endpoint.get("rsync_ssh") or _sibling_ssh() or "ssh")
    return " ".join([ssh_program, *port_opts, *SSH_BATCH_OPTS])


def rsync_push_argv(
    remote_spec: str, port_opts: list[str], endpoint: dict[str, Any] | None = None
) -> list[str]:
    """rsync argv pushing the repo to ``remote_spec`` (``user@host:path``).

    The source is the literal ``./``: the caller runs rsync with
    ``cwd=repo_root``. A cwd-relative source keeps Windows drive-letter paths
    (``D:/...``) out of the argv, where rsync would parse the colon as a
    host separator.
    """
    argv = ["rsync", "-az", "--delete", "-e", _rsync_transport(endpoint or {}, port_opts)]
    for pattern in RSYNC_EXCLUDES:
        argv += ["--exclude", pattern]
    # Trailing slash on the source copies the contents into the destination dir.
    argv += ["./", f"{remote_spec}/"]
    return argv


def rsync_pull_argv(
    destination: str,
    remote_path: str,
    root: str,
    port_opts: list[str],
    endpoint: dict[str, Any] | None = None,
) -> list[str]:
    """rsync argv pulling ONE artifact ``root`` back into ``cwd`` (= repo_root).

    ``--relative`` with the ``/./`` anchor recreates the root's path under the
    local repo, creating implied directories as needed. One invocation per
    root: multi-source forms (``user@host:p1 :p2``) need an rsync >= 3.0
    client, which a macOS dispatch host's stock rsync 2.6.9 is not.
    """
    return [
        "rsync",
        "-az",
        "--relative",
        "-e",
        _rsync_transport(endpoint or {}, port_opts),
        f"{destination}:{remote_path}/./{root}",
        ".",
    ]


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


def _warn_local_overrides(repo_root: Path, *, prefix: str = "") -> None:
    overrides = [
        name
        for name in ("pubspec_overrides.yaml", "go.work")
        if (repo_root / name).exists()
    ]
    if overrides:
        joined = ", ".join(overrides)
        locked_print(
            f"{prefix}warning: {joined} present in {repo_root}; container/VM builds "
            "use committed pins (GOWORK=off bypasses go.work; remove "
            "pubspec_overrides.yaml for a clean Flutter build)."
        )


def run_docker_target(
    config: ProductConfig,
    targets: list[str],
    endpoint: dict[str, Any],
    stamp: Stamp,
    args: argparse.Namespace,
    *,
    prefix: str = "",
) -> None:
    _warn_local_overrides(config.repo_root, prefix=prefix)
    argv = docker_argv(config, targets, endpoint, stamp, args)
    run_argv(argv, TOOL_ROOT, dict(os.environ), getattr(args, "dry_run", False), prefix=prefix)


def run_ssh_target(
    config: ProductConfig,
    host_os: str,
    targets: list[str],
    endpoint: dict[str, Any],
    stamp: Stamp,
    args: argparse.Namespace,
    *,
    prefix: str = "",
) -> None:
    dry_run = getattr(args, "dry_run", False)
    destination, port_opts = _ssh_base(
        endpoint, host_override=getattr(args, "container_host", None)
    )
    remote_repo = _remote_repo(endpoint, config.slug)
    remote_path = _rsync_remote_path(remote_repo)
    launcher = _default_launcher(host_os, endpoint)
    shell = _remote_shell(host_os, endpoint)
    env = dict(os.environ)
    ssh_argv = ["ssh", *port_opts, *SSH_BATCH_OPTS, destination]
    roots = artifact_pull_roots(config, targets, prefix=prefix)

    # 0. Prepare the remote repo dir: mkdir -p (rsync does not create its
    #    destination, so the first push to a fresh VM would fail) and delete
    #    stale declared-artifact roots from previous builds.
    prepare = remote_prepare_command(shell, remote_repo, roots)
    run_argv([*ssh_argv, prepare], TOOL_ROOT, env, dry_run, prefix=prefix)

    # 1. Push a clean copy of the repo (committed-pins; overrides excluded).
    #    cwd=repo_root: the rsync source is the literal ``./`` (see
    #    rsync_push_argv on why drive-letter paths must stay out of the argv).
    push = rsync_push_argv(f"{destination}:{remote_path}", port_opts, endpoint)
    run_argv(push, config.repo_root, env, dry_run, prefix=prefix)

    # 2. Run the build inside the VM. The remote command is ONE argv element,
    #    so no local shell ever re-parses it (reliable from native Windows
    #    too). Forwarded env values are embedded in it, so the echoed line
    #    redacts them.
    env_pairs = container_env_pairs(config, stamp)
    secrets = [
        value
        for name, value in env_pairs
        if name not in ("CBUILD_VERSION", "CBUILD_BUILD_NUMBER")
    ]
    sub_args = build_subcommand_args(config, targets, args, repo_root=".")
    remote = remote_command(shell, remote_repo, env_pairs, launcher, sub_args)
    run_argv(
        [*ssh_argv, remote], TOOL_ROOT, env, dry_run, prefix=prefix, redact=secrets
    )

    # 3. Pull the declared artifact paths back so `artifacts` finds them on
    #    the host -- one rsync per root (stock macOS rsync cannot parse
    #    multi-source remote args). A missing root (rsync exit 23) downgrades
    #    to a warning: the build itself succeeded, and the host-side
    #    `artifacts` step is the authoritative check on which outputs exist.
    if not roots:
        locked_print(
            f"{prefix}warning: no artifact roots to pull back for "
            f"{', '.join(targets)}."
        )
        return
    for root in roots:
        pull = rsync_pull_argv(destination, remote_path, root, port_opts, endpoint)
        try:
            run_argv(pull, config.repo_root, env, dry_run, prefix=prefix)
        except subprocess.CalledProcessError as exc:
            if exc.returncode != 23:
                raise
            locked_print(
                f"{prefix}warning: '{root}' was not found on the VM (rsync "
                "exit 23); `artifacts` will report what is missing."
            )


def _dispatch_host(
    config: ProductConfig,
    profile_name: str,
    profile: dict[str, Any],
    host_os: str,
    host_targets: list[str],
    stamp: Stamp,
    args: argparse.Namespace,
    *,
    prefix: str = "",
) -> tuple[str, str] | None:
    """Build one host group; return ``(where, message)`` on failure, else None."""
    label = " ".join(host_targets)
    try:
        endpoint = host_endpoint(profile, host_os)
        kind = str(endpoint.get("kind") or "").lower()
        if kind == "docker":
            run_docker_target(config, host_targets, endpoint, stamp, args, prefix=prefix)
        elif kind == "ssh":
            run_ssh_target(
                config, host_os, host_targets, endpoint, stamp, args, prefix=prefix
            )
        else:
            raise BuildError(
                f"container profile '{profile_name}' {host_os} endpoint has "
                f"unknown kind '{kind}' (expected 'docker' or 'ssh')."
            )
    except (BuildError, subprocess.CalledProcessError, OSError) as exc:
        # OSError: a transport binary or path problem (e.g. rsync's spawned
        # ssh missing) is a per-host failure, not a CLI crash -- it must
        # participate in keep-going aggregation like any other failure.
        if isinstance(exc, subprocess.CalledProcessError):
            message = f"command failed with exit code {exc.returncode}"
        elif isinstance(exc, FileNotFoundError):
            message = f"required tool not found: {exc.filename or exc}"
        else:
            message = str(exc)
        locked_print(f"{prefix}failed: {host_os} ({label}): {message}")
        return (f"{host_os}: {label}", message)
    return None


def _require_transport_tools(
    profile: dict[str, Any], grouped: dict[str, list[str]], args: argparse.Namespace
) -> None:
    """Fail fast when the dispatch host lacks the transport tools a run needs.

    docker-kind groups need a running docker engine; ssh-kind groups need ssh
    and rsync on PATH. Checked up front (instead of failing mid-dispatch) and
    skipped for --dry-run previews and --no-check-tools.
    """
    if getattr(args, "dry_run", False) or not getattr(args, "check_tools", True):
        return
    needed: list[str] = []
    for host_os in grouped:
        endpoint = profile.get(host_os)
        kind = str(endpoint.get("kind") or "").lower() if isinstance(endpoint, dict) else ""
        if kind == "docker" and "docker" not in needed:
            needed.append("docker")
        elif kind == "ssh":
            for tool in ("ssh", "rsync"):
                if tool not in needed:
                    needed.append(tool)
    missing = []
    for tool in needed:
        ok, detail = tool_status(tool)
        if not ok:
            missing.append(f"{tool} ({detail})")
    if missing:
        raise BuildError(
            "Container dispatch needs tools this host is missing: "
            + "; ".join(missing)
            + ". Install them or pass --no-check-tools to skip this check."
        )


def cmd_container_build(config: ProductConfig, args: argparse.Namespace) -> int:
    profile_name = getattr(args, "container_profile", None) or default_profile_name()
    profile = container_profile_config(profile_name)
    targets = config.expand_targets(getattr(args, "targets", None) or ["desktop"])
    stamp = compute_stamp(config)
    grouped = group_targets_by_host(config, targets)
    if not grouped:
        raise BuildError("No targets could be routed to a container/VM host.")
    _require_transport_tools(profile, grouped, args)

    print(
        f"{style_prefix('==>')} {config.display_name}: container build "
        f"({stamp.full}) via profile '{profile_name}'"
    )

    # Host groups are independent (different machines / a local container), so
    # they dispatch concurrently by default, each output line prefixed with its
    # host. Sequential fallbacks: a single group (nothing to parallelize),
    # --no-parallel-hosts, --no-keep-going (abort-on-first-failure needs an
    # order), and --dry-run (a preview should read top-to-bottom).
    parallel = (
        getattr(args, "parallel_hosts", True)
        and len(grouped) > 1
        and getattr(args, "keep_going", True)
        and not getattr(args, "dry_run", False)
    )

    failures: list[tuple[str, str]] = []
    if parallel:
        print(f"dispatching {len(grouped)} OS hosts in parallel: {', '.join(grouped)}")
        pool = ThreadPoolExecutor(max_workers=len(grouped))
        try:
            futures = [
                pool.submit(
                    _dispatch_host,
                    config,
                    profile_name,
                    profile,
                    host_os,
                    host_targets,
                    stamp,
                    args,
                    prefix=f"[{host_os}] ",
                )
                for host_os, host_targets in grouped.items()
            ]
            failures = [failure for future in futures if (failure := future.result())]
        except KeyboardInterrupt:
            # The signal lands on the MAIN thread only; the workers are blocked
            # in process.wait() and would keep the CLI alive until the remote
            # builds finish. Kill their children so the workers unblock, then
            # let the interrupt propagate.
            locked_print("interrupted: terminating container/VM dispatch...")
            terminate_active_processes()
            pool.shutdown(wait=False, cancel_futures=True)
            raise
        finally:
            pool.shutdown(wait=True)
    else:
        for host_os, host_targets in grouped.items():
            failure = _dispatch_host(
                config, profile_name, profile, host_os, host_targets, stamp, args
            )
            if failure:
                failures.append(failure)
                if not getattr(args, "keep_going", True):
                    break

    if failures:
        print("\n## Container build summary")
        for where, message in failures:
            print(f"failed: {where}: {message}")
        return 1
    return 0
