"""Target execution, artifact collection, and repo synchronization."""

from __future__ import annotations

import glob
import shutil
import subprocess
from pathlib import Path

from .config import (
    ProductConfig,
    Stamp,
    git_output,
    git_try_output,
    host_list,
    resolve_path,
)
from .environment import build_env, target_env_values
from .errors import BuildError
from .flutter import (
    flutter_build_command,
    maybe_flutter_create,
    maybe_flutter_pub_get,
)
from .process import display_command, run_command, style_prefix
from .tools import ensure_host, require_target_tools

# Pre-build git housekeeping (status/pull/fetch) must not hang the build; bound
# every auxiliary git call below.
GIT_TIMEOUT = 120


def run_target(
    config: ProductConfig,
    target_name: str,
    stamp: Stamp,
    dry_run: bool,
    build_mode: str,
    extra_args: list[str],
    skip_unsupported: bool,
    extra_env: dict[str, str] | None = None,
    check_tools: bool = True,
) -> None:
    target = config.target(target_name)
    if not ensure_host(target_name, target, skip_unsupported):
        return
    if check_tools and not dry_run:
        require_target_tools(config, target_name, target)

    env = build_env(config, stamp, extra_env)
    env.update(target_env_values(target, env))
    print(f"\n{style_prefix('==>')} {config.display_name}: {target_name} ({stamp.full})")

    cwd = resolve_path(target.get("cwd", "."), config.repo_root)
    for command in host_list(target.get("pre")):
        run_command(str(command), cwd, env, dry_run)

    commands = host_list(target.get("commands"))
    if commands:
        for command in commands:
            run_command(str(command), cwd, env, dry_run)
    else:
        maybe_flutter_pub_get(config, target, env, dry_run)
        maybe_flutter_create(config, target_name, target, env, dry_run)
        command = flutter_build_command(config, target_name, target, stamp, env, build_mode, extra_args)
        run_command(command, config.app_dir, env, dry_run)

    for command in host_list(target.get("post")):
        run_command(str(command), cwd, env, dry_run)


_PUBSPEC_DEP_SECTIONS = ("dependencies", "dev_dependencies", "dependency_overrides")


def _first_party_pin_overrides(content: str) -> tuple[bool, list[str]]:
    """Build the neutralizing override entries for one pubspec.

    Returns ``(has_committed_override_block, override_entry_lines)``. For
    every package named in the committed ``dependency_overrides:`` block that
    also carries a ``git:`` pin in the app's own ``dependencies`` /
    ``dev_dependencies``, the pinned block is returned verbatim (two-space
    indentation preserved). Re-stating the app's pins as OVERRIDES makes them
    authoritative: pub's dependency_overrides bypass version solving, so
    transitive first-party pin lag (a pinned client demanding an older forge
    ref than the app pins) cannot fail the build -- the same semantics the
    sibling-path overrides give the local dev workflow.
    """
    lines = content.splitlines()
    section: str | None = None
    overridden: list[str] = []
    pinned: dict[str, list[str]] = {}
    index = 0
    while index < len(lines):
        line = lines[index]
        stripped = line.strip()
        indent = len(line) - len(line.lstrip())
        if stripped and not stripped.startswith("#") and indent == 0 and ":" in stripped:
            section = stripped.split(":", 1)[0]
            index += 1
            continue
        if (
            section in _PUBSPEC_DEP_SECTIONS
            and stripped
            and not stripped.startswith("#")
            and indent == 2
        ):
            name = stripped.split(":", 1)[0]
            block = [line]
            cursor = index + 1
            while cursor < len(lines):
                child = lines[cursor]
                child_stripped = child.strip()
                if child_stripped and not child_stripped.startswith("#"):
                    if len(child) - len(child.lstrip()) <= 2:
                        break
                block.append(child)
                cursor += 1
            while block and not block[-1].strip():
                block.pop()
            if section == "dependency_overrides":
                overridden.append(name)
            elif any(item.strip().startswith("git:") for item in block):
                pinned.setdefault(name, block)
            index = cursor
            continue
        index += 1
    entries = [
        item for name in overridden if name in pinned for item in pinned[name]
    ]
    return (bool(overridden), entries)


def neutralize_path_overrides(repo_root: Path) -> list[Path]:
    """Disarm committed sibling-path ``dependency_overrides`` for isolated builds.

    Product repos may COMMIT a ``dependency_overrides:`` block pointing
    first-party packages at sibling checkouts (``../forge``, ...) for the
    local dev workflow. Those siblings do not exist inside a container/VM
    work copy, so resolution would fail before the git pins in
    ``dependencies:`` ever apply. pub's rule: a ``pubspec_overrides.yaml``
    REPLACES the pubspec's override block wholesale -- so each affected
    pubspec gets one carrying the app's own git pins as overrides (see
    :func:`_first_party_pin_overrides`), or an empty block when the app pins
    nothing. Only called when ``CBUILD_CONTAINER_BUILD`` is set: the work
    copy is disposable transport state, never a developer checkout.
    """
    written: list[Path] = []
    for pubspec in sorted(repo_root.rglob("pubspec.yaml")):
        parts = pubspec.relative_to(repo_root).parts
        if any(part in (".dart_tool", "build", ".pub-cache", ".git") for part in parts):
            continue
        try:
            content = pubspec.read_text(encoding="utf-8")
        except OSError:
            continue
        has_block, entries = _first_party_pin_overrides(content)
        if not has_block:
            continue
        overrides_file = pubspec.parent / "pubspec_overrides.yaml"
        body = "\n".join(entries)
        overrides_file.write_text(
            "# Written by cepheus-build for container/VM builds: replaces the\n"
            "# committed sibling-path overrides (unresolvable in an isolated\n"
            "# copy) with the app's own git pins, which override transitive\n"
            "# first-party pin lag.\n"
            "dependency_overrides:\n" + (f"{body}\n" if body else ""),
            encoding="utf-8",
        )
        written.append(overrides_file)
        print(f"neutralized path overrides: {overrides_file.relative_to(repo_root)}")
    return written


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


def run_git(args: list[str], cwd: Path, dry_run: bool = False) -> None:
    display = display_command("git", args)
    print(f"{style_prefix('+')} {display}", flush=True)
    if dry_run:
        return
    subprocess.run(["git", *args], cwd=cwd, check=True, timeout=GIT_TIMEOUT)


def try_run_git(args: list[str], cwd: Path, dry_run: bool = False) -> bool:
    display = display_command("git", args)
    print(f"{style_prefix('+')} {display}", flush=True)
    if dry_run:
        return True
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=GIT_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        print(f"warning: git {args[0]} timed out after {GIT_TIMEOUT}s", flush=True)
        return False
    if result.stdout:
        print(result.stdout, end="", flush=True)
    return result.returncode == 0


def remote_branch_exists(repo_root: Path, remote: str, branch: str) -> bool:
    ref = f"refs/remotes/{remote}/{branch}"
    try:
        result = subprocess.run(
            ["git", "show-ref", "--verify", "--quiet", ref],
            cwd=repo_root,
            timeout=GIT_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return False
    return result.returncode == 0


def working_tree_dirty(repo_root: Path) -> bool:
    """Return True if ``git status --porcelain`` reports uncommitted changes.

    On error or timeout, conservatively report not-dirty so the best-effort
    sync path is preserved; callers that demand a clean tree get the explicit
    ``require_clean`` check in :func:`sync_repo_before_build`.
    """

    output = git_try_output(["status", "--porcelain"], repo_root)
    return bool(output)


def sync_repo_before_build(
    repo_root: Path,
    dry_run: bool = False,
    require_clean: bool = False,
) -> None:
    if not repo_root.exists():
        raise BuildError(f"repo_root does not exist: {repo_root}")
    try:
        inside = git_output(["rev-parse", "--is-inside-work-tree"], repo_root)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        print(f"skip: {repo_root} is not a git worktree")
        return
    if inside.strip().lower() != "true":
        print(f"skip: {repo_root} is not a git worktree")
        return
    if working_tree_dirty(repo_root):
        if require_clean:
            raise BuildError(
                f"working tree at {repo_root} has uncommitted changes "
                "(--require-clean); commit or stash them first"
            )
        print(f"warning: {repo_root} has uncommitted changes; building a dirty tree")
    print(f"update: {repo_root}", flush=True)
    upstream = git_try_output(
        ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
        repo_root,
    )
    if upstream:
        if not try_run_git(["pull", "--ff-only"], repo_root, dry_run):
            print(
                f"warning: could not fast-forward {repo_root}; "
                "continuing with current checkout"
            )
    else:
        origin = git_try_output(["remote", "get-url", "origin"], repo_root)
        if not origin:
            print("skip: no origin remote configured; continuing without pull")
        else:
            branch = git_try_output(["branch", "--show-current"], repo_root)
            if branch:
                print(f"update: branch '{branch}' has no upstream; fetching origin")
            else:
                print("update: detached HEAD has no upstream; fetching origin")
            run_git(["fetch", "origin"], repo_root, dry_run)
            if branch and remote_branch_exists(repo_root, "origin", branch):
                ok = try_run_git(
                    ["pull", "--ff-only", "origin", branch],
                    repo_root,
                    dry_run,
                )
                if not ok:
                    print(
                        f"warning: could not fast-forward {repo_root}; "
                        "continuing with current checkout"
                    )
            elif branch:
                print(f"skip: origin/{branch} does not exist; continuing without pull")

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
