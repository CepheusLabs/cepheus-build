"""Pseudo-version pin synchronisation for first-party Go modules.

Local development resolves ``github.com/cepheuslabs/*`` siblings through the
generated (ignored) ``go.work``; CI and standalone builds have no workspace
and use the committed pseudo-version pins. ``gopins`` keeps those pins honest:
it compares each pin's embedded commit against the sibling checkout's HEAD
and, with ``--write``, advances stale pins via ``go get module@<head>``
followed by one ``go mod tidy`` — so the whole first-party set moves together
instead of drifting per consumer.

All ``go`` invocations run with ``GOWORK=off``: pin state must be computed the
way CI sees it (pins only), never through the local workspace overlay.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .dependency_model import GO_MODULES

# Both require forms: inside a require ( ... ) block and the single-line
# `require module version` form.
_REQUIRE_RE = re.compile(r"^\s*(?:require\s+)?(github\.com/cepheuslabs/[\w.-]+)\s+(v\S+)(\s*//.*)?$")
# All pseudo-version shapes end `<sep>yyyymmddhhmmss-sha12` where <sep> is `-`
# (vX.Y.Z-timestamp-sha) or `.` (vX.Y.Z-0.timestamp-sha / -pre.0.timestamp-sha).
_PSEUDO_RE = re.compile(r"[-.](\d{14})-([0-9a-f]{12})$")

# Statuses a pin row can report. "non-pseudo" (a real tag) and "unknown-module"
# (not in GO_MODULES — extend the manifest) are surfaced but never auto-synced.
STATUS_OK = "ok"
STATUS_STALE = "stale"
STATUS_NON_PSEUDO = "non-pseudo"
STATUS_MISSING_SIBLING = "missing-sibling"
STATUS_UNKNOWN_MODULE = "unknown-module"


@dataclass(frozen=True)
class PinRow:
    module: str
    version: str
    pinned_sha: str | None
    head_sha: str | None
    repo_dir: str | None
    indirect: bool

    @property
    def status(self) -> str:
        if self.repo_dir is None:
            return STATUS_UNKNOWN_MODULE
        if self.head_sha is None:
            return STATUS_MISSING_SIBLING
        if self.pinned_sha is None:
            return STATUS_NON_PSEUDO
        return STATUS_OK if self.head_sha.startswith(self.pinned_sha) else STATUS_STALE


def parse_requires(go_mod_text: str) -> list[tuple[str, str, bool]]:
    """Return (module, version, indirect) for every first-party require line."""
    out: list[tuple[str, str, bool]] = []
    for line in go_mod_text.splitlines():
        if line.lstrip().startswith("//"):
            continue
        match = _REQUIRE_RE.match(line)
        if not match:
            continue
        module, version, comment = match.group(1), match.group(2), match.group(3) or ""
        out.append((module, version, "// indirect" in comment))
    return out


def pseudo_sha(version: str) -> str | None:
    """The 12-hex commit prefix embedded in a pseudo-version, else None."""
    match = _PSEUDO_RE.search(version)
    return match.group(2) if match else None


def git_head(repo: Path) -> str | None:
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def plan(
    go_mod_text: str,
    workspace_root: Path,
    *,
    head_for: Callable[[Path], str | None] = git_head,
) -> list[PinRow]:
    rows: list[PinRow] = []
    for module, version, indirect in parse_requires(go_mod_text):
        package = GO_MODULES.get(module)
        repo_dir = package.repo if package else None
        head = head_for(workspace_root / repo_dir) if repo_dir else None
        rows.append(PinRow(module, version, pseudo_sha(version), head, repo_dir, indirect))
    return rows


def apply(rows: list[PinRow], repo: Path, *, runner: Callable[[Path, list[str]], bool] | None = None) -> list[str]:
    """Advance every stale pin, then tidy once. Returns failure messages."""
    run = runner or _run_go
    failures: list[str] = []
    stale = [row for row in rows if row.status == STATUS_STALE]
    for row in stale:
        if not run(repo, ["go", "get", f"{row.module}@{row.head_sha}"]):
            failures.append(f"go get {row.module}@{row.head_sha} failed")
    if stale and not failures:
        if not run(repo, ["go", "mod", "tidy"]):
            failures.append("go mod tidy failed")
    return failures


def _run_go(repo: Path, argv: list[str]) -> bool:
    env = dict(os.environ)
    env["GOWORK"] = "off"  # pins are the CI view; never resolve through go.work
    env.setdefault("GOPRIVATE", "github.com/cepheuslabs/*,github.com/CepheusLabs/*")
    env.setdefault("GOTOOLCHAIN", "auto")
    try:
        proc = subprocess.run(
            argv,
            cwd=str(repo),
            env=env,
            capture_output=True,
            text=True,
            timeout=600,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        sys.stderr.write(f"{' '.join(argv)}: {exc}\n")
        return False
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr[-2000:])
    return proc.returncode == 0
