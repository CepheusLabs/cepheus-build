"""Release tag creation: annotated CalVer tags pushed to the product repo.

A release IS an annotated git tag (release-pipeline locked decision L5):
``v<YY.M.D>-<count>`` for the stable channel, ``beta-v<YY.M.D>-<count>`` for
beta — exactly the string every ``github_release`` lane targets and the string
``app-release.yml``'s prepare job parses back into ``CBUILD_VERSION`` /
``CBUILD_BUILD_NUMBER``. ``compute_stamp`` is consulted only here, at
tag-creation time; after that the tag is authoritative.

All git interaction goes through :func:`git_capture` (read-only checks) and
:func:`run_git` (tag + push), so tests monkeypatch those instead of running
real git against product repos.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

from .builder import run_git
from .config import GIT_TIMEOUT, ProductConfig, Stamp
from .errors import BuildError

# Channel -> tag prefix. The channel set is deliberately closed: nightly has
# no tag (scheduled callers pass channel=nightly with no ref; plan Phase 5.1).
CHANNEL_TAG_PREFIXES = {"stable": "", "beta": "beta-"}


def release_tag_name(stamp: Stamp, channel: str) -> str:
    """``v{version}-{build_number}`` with the channel's tag prefix."""
    try:
        prefix = CHANNEL_TAG_PREFIXES[channel]
    except KeyError:
        raise BuildError(
            f"Unknown release channel '{channel}'. "
            f"Valid channels: {', '.join(sorted(CHANNEL_TAG_PREFIXES))}."
        ) from None
    return f"{prefix}v{stamp.version}-{stamp.build_number}"


def git_capture(args: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    """Run git capturing output; non-zero exit is reported, never raised."""
    return subprocess.run(
        ["git", *args],
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=GIT_TIMEOUT,
    )


def ensure_release_preconditions(repo_root: Path, tag: str) -> None:
    """Hard gates before tagging: worktree, clean tree, tag not taken.

    Unlike the best-effort build sync (``working_tree_dirty`` tolerates git
    errors), a release fails CLOSED: any check that cannot be answered
    positively aborts.
    """
    worktree = git_capture(["rev-parse", "--is-inside-work-tree"], repo_root)
    if worktree.returncode != 0 or worktree.stdout.strip().lower() != "true":
        raise BuildError(f"{repo_root} is not a git worktree; cannot create a release tag.")

    status = git_capture(["status", "--porcelain"], repo_root)
    if status.returncode != 0:
        raise BuildError(f"git status failed in {repo_root}: {status.stderr.strip()}")
    if status.stdout.strip():
        raise BuildError(
            f"working tree at {repo_root} has uncommitted changes; "
            "commit or stash them before releasing."
        )

    local = git_capture(["show-ref", "--verify", "--quiet", f"refs/tags/{tag}"], repo_root)
    if local.returncode == 0:
        raise BuildError(f"tag {tag} already exists in {repo_root}.")

    remote = git_capture(["ls-remote", "--tags", "origin", f"refs/tags/{tag}"], repo_root)
    if remote.returncode != 0:
        raise BuildError(
            f"could not query origin for existing tags in {repo_root}: "
            f"{remote.stderr.strip() or 'ls-remote failed'}"
        )
    if remote.stdout.strip():
        raise BuildError(f"tag {tag} already exists on origin.")


def create_release_tag(
    config: ProductConfig,
    stamp: Stamp,
    channel: str = "stable",
    dry_run: bool = False,
) -> str:
    """Create and push the annotated release tag in the product's repo.

    Returns the tag name. ``dry_run`` still runs the read-only precondition
    checks (so a dry run validates the real state) but prints the tag/push
    commands instead of executing them.
    """
    tag = release_tag_name(stamp, channel)
    repo_root = config.repo_root
    if not repo_root.exists():
        raise BuildError(f"repo_root does not exist: {repo_root}")
    ensure_release_preconditions(repo_root, tag)

    message = f"{config.display_name} {stamp.version} build {stamp.build_number} ({channel})"
    run_git(["tag", "-a", tag, "-m", message], repo_root, dry_run)
    run_git(["push", "origin", f"refs/tags/{tag}"], repo_root, dry_run)
    return tag
