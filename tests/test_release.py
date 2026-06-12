"""Tests for the `release` command's tag formation and git preconditions.

Git is monkeypatched throughout (`release.git_capture` for the read-only
checks, `release.run_git` for tag/push) — no real git ever runs against a
product repo here, mirroring the recorded-run style of test_builder.py.
"""

from __future__ import annotations

import subprocess
import textwrap

import pytest

from cepheus_build import release
from cepheus_build.config import ProductConfig, Stamp, load_toml
from cepheus_build.errors import BuildError

STAMP = Stamp("26.6.11", "482")


def _config(tmp_path) -> ProductConfig:
    content = textwrap.dedent("""\
        [product]
        slug = "demo"
        display_name = "Demo"
        repo_root = "."
        app_dir = "."
    """)
    path = tmp_path / "demo.toml"
    path.write_text(content)
    # repo_root resolves relative to the config's parent (tmp_path), which exists.
    return ProductConfig(path=path, data=load_toml(path))


def _proc(returncode: int, stdout: str = "", stderr: str = "") -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(args=["git"], returncode=returncode, stdout=stdout, stderr=stderr)


class FakeGit:
    """Canned `git_capture` responses keyed by git subcommand."""

    def __init__(
        self,
        *,
        worktree: bool = True,
        shallow: bool = False,
        dirty: bool = False,
        local_tag: bool = False,
        remote_tag: bool = False,
        remote_ok: bool = True,
    ):
        self.worktree = worktree
        self.shallow = shallow
        self.dirty = dirty
        self.local_tag = local_tag
        self.remote_tag = remote_tag
        self.remote_ok = remote_ok

    def __call__(self, args, cwd):
        command = args[0]
        if command == "rev-parse" and "--is-shallow-repository" in args:
            return _proc(0, "true\n" if self.shallow else "false\n")
        if command == "rev-parse":
            if self.worktree:
                return _proc(0, "true\n")
            return _proc(128, "", "fatal: not a git repository")
        if command == "status":
            return _proc(0, " M app/lib/main.dart\n" if self.dirty else "")
        if command == "show-ref":
            return _proc(0 if self.local_tag else 1)
        if command == "ls-remote":
            if not self.remote_ok:
                return _proc(128, "", "fatal: could not read from remote repository")
            return _proc(0, f"abc123\t{args[-1]}\n" if self.remote_tag else "")
        raise AssertionError(f"unexpected git call: {args}")


@pytest.fixture
def recorded_git(monkeypatch):
    """Capture run_git invocations as (args, cwd, dry_run) tuples."""
    calls: list[tuple[list[str], str, bool]] = []

    def fake_run_git(args, cwd, dry_run=False):
        calls.append((list(args), str(cwd), dry_run))

    monkeypatch.setattr(release, "run_git", fake_run_git)
    return calls


class TestReleaseTagName:
    def test_stable_channel(self):
        assert release.release_tag_name(STAMP, "stable") == "v26.6.11-482"

    def test_beta_channel_prefix(self):
        assert release.release_tag_name(STAMP, "beta") == "beta-v26.6.11-482"

    def test_unknown_channel_rejected(self):
        with pytest.raises(BuildError, match="Unknown release channel"):
            release.release_tag_name(STAMP, "nightly")


class TestCreateReleaseTag:
    def test_creates_annotated_tag_then_pushes(self, tmp_path, monkeypatch, recorded_git):
        monkeypatch.setattr(release, "git_capture", FakeGit())
        config = _config(tmp_path)
        tag = release.create_release_tag(config, STAMP)
        assert tag == "v26.6.11-482"
        assert [(args, dry) for args, _, dry in recorded_git] == [
            (["tag", "-a", "v26.6.11-482", "-m", "Demo 26.6.11 build 482 (stable)"], False),
            (["push", "origin", "refs/tags/v26.6.11-482"], False),
        ]
        # Both run in the product's repo_root, not this repo.
        assert {cwd for _, cwd, _ in recorded_git} == {str(config.repo_root)}

    def test_beta_channel_tags_with_prefix(self, tmp_path, monkeypatch, recorded_git):
        monkeypatch.setattr(release, "git_capture", FakeGit())
        tag = release.create_release_tag(_config(tmp_path), STAMP, channel="beta")
        assert tag == "beta-v26.6.11-482"
        assert recorded_git[0][0][2] == "beta-v26.6.11-482"
        assert recorded_git[1][0][2] == "refs/tags/beta-v26.6.11-482"

    def test_dry_run_passes_flag_through(self, tmp_path, monkeypatch, recorded_git):
        monkeypatch.setattr(release, "git_capture", FakeGit())
        release.create_release_tag(_config(tmp_path), STAMP, dry_run=True)
        assert [dry for _, _, dry in recorded_git] == [True, True]

    def test_dirty_tree_refused(self, tmp_path, monkeypatch, recorded_git):
        monkeypatch.setattr(release, "git_capture", FakeGit(dirty=True))
        with pytest.raises(BuildError, match="uncommitted changes"):
            release.create_release_tag(_config(tmp_path), STAMP)
        assert recorded_git == []

    def test_existing_local_tag_refused(self, tmp_path, monkeypatch, recorded_git):
        monkeypatch.setattr(release, "git_capture", FakeGit(local_tag=True))
        with pytest.raises(BuildError, match="already exists in"):
            release.create_release_tag(_config(tmp_path), STAMP)
        assert recorded_git == []

    def test_existing_remote_tag_refused(self, tmp_path, monkeypatch, recorded_git):
        monkeypatch.setattr(release, "git_capture", FakeGit(remote_tag=True))
        with pytest.raises(BuildError, match="already exists on origin"):
            release.create_release_tag(_config(tmp_path), STAMP)
        assert recorded_git == []

    def test_not_a_worktree_refused(self, tmp_path, monkeypatch, recorded_git):
        monkeypatch.setattr(release, "git_capture", FakeGit(worktree=False))
        with pytest.raises(BuildError, match="not a git worktree"):
            release.create_release_tag(_config(tmp_path), STAMP)
        assert recorded_git == []

    def test_shallow_clone_refused(self, tmp_path, monkeypatch, recorded_git):
        # rev-list --count is wrong in shallow clones, so the build number
        # (and therefore the tag) would be wrong: fail with the unshallow hint.
        monkeypatch.setattr(release, "git_capture", FakeGit(shallow=True))
        with pytest.raises(BuildError, match="shallow clone.*--unshallow"):
            release.create_release_tag(_config(tmp_path), STAMP)
        assert recorded_git == []

    def test_unreachable_origin_fails_closed(self, tmp_path, monkeypatch, recorded_git):
        monkeypatch.setattr(release, "git_capture", FakeGit(remote_ok=False))
        with pytest.raises(BuildError, match="could not query origin"):
            release.create_release_tag(_config(tmp_path), STAMP)
        assert recorded_git == []

    def test_missing_repo_root_refused(self, tmp_path, monkeypatch, recorded_git):
        monkeypatch.setattr(release, "git_capture", FakeGit())
        config = _config(tmp_path)
        config.repo_root_override = str(tmp_path / "does-not-exist")
        with pytest.raises(BuildError, match="repo_root does not exist"):
            release.create_release_tag(config, STAMP)
        assert recorded_git == []


class TestCliWiring:
    def test_release_parser_defaults(self):
        from cepheus_build.cli import build_parser

        args = build_parser().parse_args(["release", "-p", "deckhand"])
        assert args.channel == "stable"
        assert args.dry_run is False
        assert args.product == "deckhand"

    def test_release_parser_beta_dry_run(self):
        from cepheus_build.cli import build_parser

        args = build_parser().parse_args(["release", "-p", "deckhand", "--channel", "beta", "--dry-run"])
        assert args.channel == "beta"
        assert args.dry_run is True

    def test_release_parser_rejects_unknown_channel(self, capsys):
        from cepheus_build.cli import build_parser

        with pytest.raises(SystemExit):
            build_parser().parse_args(["release", "-p", "deckhand", "--channel", "nightly"])
