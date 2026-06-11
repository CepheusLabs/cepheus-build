"""Tests for cepheus_build.deploy.google_play: validation + dry-run lane.

Only the paths that run BEFORE the lazy google imports are exercised, so the
suite needs neither google-api-python-client nor network access. The real
upload path stays covered by `deploy <lane> --dry-run` against products.
"""

from __future__ import annotations

import argparse

from cepheus_build.deploy import google_play


def _files(tmp_path):
    aab = tmp_path / "app-release.aab"
    aab.write_bytes(b"not really an aab")
    sa = tmp_path / "service-account.json"
    sa.write_text("{}")
    return aab, sa


def _argv(aab, sa, *extra):
    return [
        "--aab",
        str(aab),
        "--package",
        "com.example.demo",
        "--service-account",
        str(sa),
        *extra,
    ]


class TestIsDryRun:
    def _args(self, dry_run=False):
        return argparse.Namespace(dry_run=dry_run)

    def test_flag_wins(self, monkeypatch):
        monkeypatch.delenv("CBUILD_DRY_RUN", raising=False)
        assert google_play._is_dry_run(self._args(dry_run=True)) is True

    def test_env_one_enables(self, monkeypatch):
        monkeypatch.setenv("CBUILD_DRY_RUN", "1")
        assert google_play._is_dry_run(self._args()) is True

    def test_falsy_env_values_disable(self, monkeypatch):
        for value in ("", "0", "false", "no"):
            monkeypatch.setenv("CBUILD_DRY_RUN", value)
            assert google_play._is_dry_run(self._args()) is False

    def test_unset_env_disables(self, monkeypatch):
        monkeypatch.delenv("CBUILD_DRY_RUN", raising=False)
        assert google_play._is_dry_run(self._args()) is False


class TestDryRunLane:
    def test_dry_run_plans_without_api_calls(self, tmp_path, capsys, monkeypatch):
        monkeypatch.delenv("CBUILD_DRY_RUN", raising=False)
        aab, sa = _files(tmp_path)
        rc = google_play.main(_argv(aab, sa, "--dry-run", "--track", "internal"))
        assert rc == 0
        out = capsys.readouterr().out
        assert "[dry-run]" in out
        assert "com.example.demo" in out
        assert "track 'internal'" in out
        assert "No API calls made" in out

    def test_env_var_triggers_dry_run(self, tmp_path, capsys, monkeypatch):
        monkeypatch.setenv("CBUILD_DRY_RUN", "1")
        aab, sa = _files(tmp_path)
        rc = google_play.main(_argv(aab, sa))
        assert rc == 0
        assert "No API calls made" in capsys.readouterr().out


class TestInputValidation:
    """These guards run before dry-run AND before the lazy google imports."""

    def test_missing_aab_fails(self, tmp_path, capsys):
        _aab, sa = _files(tmp_path)
        rc = google_play.main(_argv(tmp_path / "absent.aab", sa, "--dry-run"))
        assert rc == 2
        assert "AAB not found" in capsys.readouterr().err

    def test_missing_service_account_fails(self, tmp_path, capsys):
        aab, _sa = _files(tmp_path)
        rc = google_play.main(_argv(aab, tmp_path / "absent.json", "--dry-run"))
        assert rc == 2
        assert "service account JSON not found" in capsys.readouterr().err

    def test_service_account_json_body_rejected(self, tmp_path, capsys):
        aab, _sa = _files(tmp_path)
        rc = google_play.main(_argv(aab, '{"type": "service_account"}', "--dry-run"))
        assert rc == 2
        assert "must be a file path" in capsys.readouterr().err
