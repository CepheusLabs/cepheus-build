"""Process execution: PATH augmentation, streaming, and command repairs.

Trust boundary
--------------
The shell command strings executed by :func:`run_command` and
:func:`run_shell_streaming` originate from the product TOML files checked into
*this* repository (``products/*.toml``). Those strings are TRUSTED input:
maintainers control them and they intentionally run with ``shell=True`` so that
pipes, env interpolation, and multi-step build recipes work.

This trust does NOT extend to arbitrary, repo-supplied configuration. A
``.cepheus-build.toml`` / ``--config`` discovered inside an untrusted product
checkout must never have its command strings fed to these helpers blindly --
doing so would be remote code execution. Only command strings sourced from the
vetted ``products/`` directory should reach the shell here.

:func:`run_shell_streaming` is also intentionally left WITHOUT a timeout: real
builds legitimately run for a long time. Only the short auxiliary commands (tool
checks in tools.py, git sync in builder.py/config.py, gh dispatch in github.py)
are time-bounded.
"""

from __future__ import annotations

import os
import shlex
import signal
import subprocess
import sys
import threading
from collections import deque
from pathlib import Path
from typing import Any

from .errors import BuildError

COCOAPODS_SPECS_REPAIR_PATTERNS = [
    "CocoaPods's specs repository is too out-of-date",
    "CocoaPods could not find compatible versions for pod",
]

COMMAND_OUTPUT_FAILURE_PATTERNS = [
    "Encountered error while creating the IPA:",
    "exportArchive Failed",
    # Flutter desktop builds (notably Windows, where flutter.bat / the MSBuild
    # link step can swallow the non-zero exit code) print this on failure while
    # still returning 0. Detect the failure from the output so a broken build
    # can't masquerade as success.
    "Build process failed.",
]

# Color is opt-out: a global override set from the CLI (``--no-color``) stacks on
# top of the ``NO_COLOR`` convention and a tty check. The GUI and CI both capture
# stdout (non-tty), so color stays off there and output stays byte-stable.
_COLOR_FORCE_OFF = False

# Serializes line writes when several streamed subprocesses share stdout (the
# container backend's parallel per-host dispatch). Single-process streaming is
# unaffected: the lock is uncontended.
_PRINT_LOCK = threading.Lock()

# Live subprocesses spawned by _run_streaming, so a KeyboardInterrupt in the
# main thread can terminate children started by WORKER threads (the parallel
# container dispatch) -- their own KeyboardInterrupt handling never fires
# because the signal is delivered to the main thread only.
_ACTIVE_PROCESSES: set[subprocess.Popen[str]] = set()
_ACTIVE_LOCK = threading.Lock()


def locked_print(message: str) -> None:
    """Whole-line print under the shared output lock (parallel-dispatch safe)."""
    with _PRINT_LOCK:
        print(message, flush=True)


def terminate_active_processes() -> None:
    """Terminate every live streamed subprocess (Ctrl-C in parallel dispatch)."""
    with _ACTIVE_LOCK:
        active = list(_ACTIVE_PROCESSES)
    for process in active:
        terminate_process_tree(process)


def set_color_enabled(enabled: bool | None = None, *, no_color: bool | None = None) -> None:
    """Globally turn ANSI color off.

    Accepts either calling convention used by the CLI:
    ``set_color_enabled(False)`` / ``set_color_enabled(enabled=...)`` disables
    color when the value is falsy, and ``set_color_enabled(no_color=True)``
    disables it when the flag is truthy. When neither argument is provided this
    is a no-op (color stays governed by NO_COLOR / tty detection).
    """

    global _COLOR_FORCE_OFF
    if no_color:
        _COLOR_FORCE_OFF = True
    if enabled is not None and not enabled:
        _COLOR_FORCE_OFF = True


def use_color(stream: Any = None) -> bool:
    """Return whether ANSI color should be emitted to ``stream`` (default stdout).

    False when ``--no-color`` was passed, ``NO_COLOR`` is set in the
    environment, or the stream is not an interactive terminal.
    """

    if _COLOR_FORCE_OFF:
        return False
    if os.environ.get("NO_COLOR") is not None:
        return False
    target = stream if stream is not None else sys.stdout
    try:
        return bool(target.isatty())
    except (AttributeError, ValueError):
        return False


def style_prefix(prefix: str) -> str:
    """Bold ``prefix`` when color is enabled; otherwise return it unchanged.

    Status markers like ``+`` and ``==>`` route through this so that the default
    (color off / non-tty, as under the GUI and CI) stays byte-identical to the
    historical plain text.
    """

    if use_color():
        return f"\033[1m{prefix}\033[0m"
    return prefix


def augment_process_path() -> None:
    candidates = [
        Path.home() / ".cargo" / "bin",
        Path.home() / ".pub-cache" / "bin",
        Path.home() / ".local" / "bin",
        # cwRsync (user-level rsync for Windows dispatch hosts).
        Path.home() / "AppData" / "Local" / "cwrsync" / "bin",
        Path("/opt/homebrew/bin"),
        Path("/opt/homebrew/sbin"),
        Path("/usr/local/bin"),
        Path("/Applications/Docker.app/Contents/Resources/bin"),
    ]
    existing = [part for part in os.environ.get("PATH", "").split(os.pathsep) if part]
    normalized = {str(Path(part).expanduser()) for part in existing}
    additions = [
        str(path)
        for path in candidates
        if path.exists() and str(path) not in normalized
    ]
    if additions:
        os.environ["PATH"] = os.pathsep.join([*additions, *existing])


def shell_quote(value: str) -> str:
    if os.name == "nt":
        return value
    return shlex.quote(value)


def display_command(executable: str, args: list[str]) -> str:
    return " ".join([shell_quote(executable), *[shell_quote(arg) for arg in args]])


def run_command(
    command: str,
    cwd: Path,
    env: dict[str, str],
    dry_run: bool = False,
    *,
    allow_repairs: bool = True,
) -> None:
    # TRUST BOUNDARY: ``command`` is a shell string sourced from a product's
    # TOML config (build/store/pre/post commands). Those product TOMLs are
    # first-party, TRUSTED input maintained in this repo, so executing them via
    # ``shell=True`` (in run_shell_streaming) is intentional. Command strings
    # coming from an UNTRUSTED repo's ``.cepheus-build.toml`` / ``--config``
    # must NOT be passed here without review -- they run arbitrary code locally.
    # (The container backend's transport commands use :func:`run_argv` instead:
    # no shell, no ``$VAR`` expansion, so remote ``$HOME`` / ``$env:...`` tokens
    # reach the remote shell intact.)
    rendered = os.path.expandvars(command)
    print(f"{style_prefix('+')} {rendered}", flush=True)
    if dry_run:
        return
    returncode, output = run_shell_streaming(rendered, cwd, env)
    if returncode == 0 and not should_treat_output_as_failure(output):
        return

    if allow_repairs and should_repair_cocoapods_specs(output):
        repair_cocoapods_specs(cwd, env, dry_run)
        print("repair: retrying failed command after CocoaPods specs update", flush=True)
        print(f"{style_prefix('+')} {rendered}", flush=True)
        returncode, output = run_shell_streaming(rendered, cwd, env)
        if returncode == 0 and not should_treat_output_as_failure(output):
            return

    raise subprocess.CalledProcessError(returncode or 1, rendered, output=output)


def run_argv(
    argv: list[str],
    cwd: Path,
    env: dict[str, str],
    dry_run: bool = False,
    *,
    prefix: str = "",
    redact: list[str] | None = None,
) -> None:
    """Execute ``argv`` directly (no shell) and stream its output.

    The argv-exec counterpart of :func:`run_command`, used by the container
    backend for its own transport commands (docker / ssh / rsync). Bypassing
    the local shell makes quoting OS-independent: every element reaches the
    child process verbatim, so an ssh remote-command string stays one argument
    even on native Windows, where :func:`shell_quote` cannot quote for cmd.exe.

    No ``$VAR`` expansion, CocoaPods repair, or output-failure scanning happens
    here -- those behaviors target product build commands, not transport.
    ``prefix`` is prepended to the echoed command and every streamed line
    (parallel per-host dispatch labels each host's output with it). ``redact``
    values are masked in the ECHOED line only (forwarded secrets embedded in
    an ssh remote command must not land in GUI/CI logs); the child still
    receives them verbatim.
    """
    rendered = display_command(argv[0], argv[1:])
    for secret in redact or []:
        rendered = rendered.replace(secret, "***")
    with _PRINT_LOCK:
        print(f"{prefix}{style_prefix('+')} {rendered}", flush=True)
    if dry_run:
        return
    try:
        returncode, output = _run_streaming(argv, cwd, env, shell=False, prefix=prefix)
    except FileNotFoundError as exc:
        raise BuildError(
            f"'{argv[0]}' not found on PATH -- the container backend needs it "
            "on the dispatch host (see docs/cross-os-builds.md; note rsync is "
            "not part of Git for Windows)."
        ) from exc
    if returncode != 0:
        raise subprocess.CalledProcessError(returncode, rendered, output=output)


def run_shell_streaming(command: str, cwd: Path, env: dict[str, str]) -> tuple[int, str]:
    # TRUST BOUNDARY: ``command`` is executed through the shell and is expected
    # to come from TRUSTED first-party product TOML, never from an untrusted
    # repo's config supplied via ``--config``.
    return _run_streaming(command, cwd, env, shell=True)


def _run_streaming(
    command: str | list[str],
    cwd: Path,
    env: dict[str, str],
    *,
    shell: bool,
    prefix: str = "",
) -> tuple[int, str]:
    # No timeout is applied here on purpose: real builds legitimately run for a
    # long time. Short auxiliary commands that can hang (tool probes, git, gh)
    # use bounded timeouts in their own modules instead.
    popen_kwargs: dict[str, Any] = {}
    if os.name != "nt":
        popen_kwargs["start_new_session"] = True
    process = subprocess.Popen(
        command,
        cwd=cwd,
        env=env,
        shell=shell,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        **popen_kwargs,
    )
    output: deque[str] = deque(maxlen=1200)
    output_lock = threading.Lock()

    def stream(pipe: Any, destination: Any) -> None:
        try:
            for line in iter(pipe.readline, ""):
                with output_lock:
                    output.append(line)
                with _PRINT_LOCK:
                    print(f"{prefix}{line}", end="", file=destination, flush=True)
        except ValueError:
            pass
        finally:
            try:
                pipe.close()
            except ValueError:
                pass

    threads = []
    if process.stdout is not None:
        threads.append(threading.Thread(target=stream, args=(process.stdout, sys.stdout), daemon=True))
    if process.stderr is not None:
        threads.append(threading.Thread(target=stream, args=(process.stderr, sys.stderr), daemon=True))
    for thread in threads:
        thread.start()

    with _ACTIVE_LOCK:
        _ACTIVE_PROCESSES.add(process)
    try:
        returncode = process.wait()
    except KeyboardInterrupt:
        terminate_process_tree(process)
        raise
    finally:
        with _ACTIVE_LOCK:
            _ACTIVE_PROCESSES.discard(process)
    for pipe in [process.stdout, process.stderr]:
        if pipe is not None and not pipe.closed:
            pipe.close()
    for thread in threads:
        thread.join(timeout=2)
    return returncode, "".join(output)


def terminate_process_tree(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    try:
        if os.name == "nt":
            process.terminate()
        else:
            os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except Exception:
        try:
            if os.name == "nt":
                process.kill()
            else:
                os.killpg(process.pid, signal.SIGKILL)
        except Exception:
            pass


def should_repair_cocoapods_specs(output: str) -> bool:
    if not output:
        return False
    if any(pattern in output for pattern in COCOAPODS_SPECS_REPAIR_PATTERNS):
        return True
    return "CocoaPods" in output and "pod repo update" in output


def should_treat_output_as_failure(output: str) -> bool:
    if not output:
        return False
    return any(pattern in output for pattern in COMMAND_OUTPUT_FAILURE_PATTERNS)


def repair_cocoapods_specs(cwd: Path, env: dict[str, str], dry_run: bool) -> None:
    command = "pod repo update"
    print("repair: CocoaPods specs repo is out-of-date; running pod repo update", flush=True)
    run_command(command, cwd, env, dry_run, allow_repairs=False)
