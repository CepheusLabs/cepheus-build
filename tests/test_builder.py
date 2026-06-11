"""Tests for the build/target execution layer.

`run_command` is monkeypatched to record invocations instead of running a
shell, so these exercise the orchestration logic (command ordering, host-skip,
dry-run, pre/post hooks, artifact globbing) without real builds.
"""

from __future__ import annotations

import textwrap

import pytest

from cepheus_build import builder
from cepheus_build.config import ProductConfig, Stamp, load_toml


def _config(tmp_path, targets_toml: str) -> ProductConfig:
    content = textwrap.dedent(f"""\
        [product]
        slug = "demo"
        display_name = "Demo"
        repo_root = "."
        app_dir = "."

        {targets_toml}
    """)
    path = tmp_path / "demo.toml"
    path.write_text(content)
    # repo_root resolves relative to the config's parent (tmp_path), which exists.
    return ProductConfig(path=path, data=load_toml(path))


@pytest.fixture
def recorded(monkeypatch):
    """Capture every run_command call as (command, cwd) tuples."""
    calls: list[tuple[str, str]] = []

    def fake_run_command(command, cwd, env, dry_run=False, **kwargs):
        calls.append((command, str(cwd)))

    monkeypatch.setattr(builder, "run_command", fake_run_command)
    # Tools are not installed in the test env; skip the prerequisite gate.
    monkeypatch.setattr(builder, "require_target_tools", lambda *a, **k: None)
    return calls


STAMP = Stamp("26.5.30", "42")


class TestRunTarget:
    def test_runs_explicit_commands_in_order(self, tmp_path, recorded):
        config = _config(
            tmp_path,
            '[targets.web]\nhosts = ["linux","macos","windows"]\n'
            'commands = ["make a", "make b"]\n',
        )
        builder.run_target(
            config=config,
            target_name="web",
            stamp=STAMP,
            dry_run=False,
            build_mode="release",
            extra_args=[],
            skip_unsupported=True,
        )
        commands = [c for c, _ in recorded]
        assert commands == ["make a", "make b"]

    def test_pre_and_post_wrap_commands(self, tmp_path, recorded):
        config = _config(
            tmp_path,
            '[targets.web]\nhosts = ["linux","macos","windows"]\n'
            'pre = ["pre1"]\ncommands = ["main"]\npost = ["post1"]\n',
        )
        builder.run_target(
            config=config,
            target_name="web",
            stamp=STAMP,
            dry_run=False,
            build_mode="release",
            extra_args=[],
            skip_unsupported=True,
        )
        assert [c for c, _ in recorded] == ["pre1", "main", "post1"]

    def test_wrong_host_is_skipped(self, tmp_path, recorded, monkeypatch):
        monkeypatch.setattr("cepheus_build.tools.current_host", lambda: "linux")
        config = _config(
            tmp_path,
            '[targets.win]\nhosts = ["windows"]\ncommands = ["build.exe"]\n',
        )
        builder.run_target(
            config=config,
            target_name="win",
            stamp=STAMP,
            dry_run=False,
            build_mode="release",
            extra_args=[],
            skip_unsupported=True,
        )
        assert recorded == []  # nothing ran — skipped for host mismatch

    def test_wrong_host_raises_when_not_skipping(self, tmp_path, recorded, monkeypatch):
        monkeypatch.setattr("cepheus_build.tools.current_host", lambda: "linux")
        config = _config(
            tmp_path,
            '[targets.win]\nhosts = ["windows"]\ncommands = ["build.exe"]\n',
        )
        with pytest.raises(builder.BuildError):
            builder.run_target(
                config=config,
                target_name="win",
                stamp=STAMP,
                dry_run=False,
                build_mode="release",
                extra_args=[],
                skip_unsupported=False,
            )


class TestNeutralizePathOverrides:
    def test_writes_empty_override_file_beside_affected_pubspec(self, tmp_path):
        (tmp_path / "pubspec.yaml").write_text(
            "name: demo\ndependency_overrides:\n  forge:\n    path: ../forge\n"
        )
        written = builder.neutralize_path_overrides(tmp_path)
        assert written == [tmp_path / "pubspec_overrides.yaml"]
        content = (tmp_path / "pubspec_overrides.yaml").read_text()
        # An empty block REPLACES the committed one (pub semantics).
        assert content.rstrip().endswith("dependency_overrides:")

    def test_pubspec_without_overrides_untouched(self, tmp_path):
        (tmp_path / "pubspec.yaml").write_text("name: demo\ndependencies:\n  intl: ^0.20.0\n")
        assert builder.neutralize_path_overrides(tmp_path) == []
        assert not (tmp_path / "pubspec_overrides.yaml").exists()

    def test_nested_app_pubspecs_covered_but_caches_skipped(self, tmp_path):
        nested = tmp_path / "apps" / "studio"
        nested.mkdir(parents=True)
        (nested / "pubspec.yaml").write_text(
            "name: studio\ndependency_overrides:\n  x:\n    path: ../x\n"
        )
        cache = tmp_path / "build" / "pkg"
        cache.mkdir(parents=True)
        (cache / "pubspec.yaml").write_text(
            "name: cached\ndependency_overrides:\n  y:\n    path: ../y\n"
        )
        written = builder.neutralize_path_overrides(tmp_path)
        assert written == [nested / "pubspec_overrides.yaml"]


class TestCollectArtifacts:
    def test_existing_artifact_is_globbed(self, tmp_path):
        # Build a product whose repo_root is tmp_path and create a matching file.
        (tmp_path / "out").mkdir()
        artifact = tmp_path / "out" / "app-release.apk"
        artifact.write_text("x")
        config = _config(
            tmp_path,
            '[targets.android]\nhosts = ["linux"]\n'
            'commands = ["build"]\nartifacts = ["out/*.apk"]\n',
        )
        found = builder.collect_artifacts(config, ["android"])
        assert any(p.name == "app-release.apk" for p in found["android"])

    def test_missing_artifact_returns_literal_path(self, tmp_path):
        config = _config(
            tmp_path,
            '[targets.android]\nhosts = ["linux"]\n'
            'commands = ["build"]\nartifacts = ["out/missing.apk"]\n',
        )
        found = builder.collect_artifacts(config, ["android"])
        # No glob match -> the literal (non-existent) path is reported so the
        # caller can show it as "missing" rather than silently dropping it.
        assert len(found["android"]) == 1
        assert not found["android"][0].exists()
