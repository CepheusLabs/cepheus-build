from __future__ import annotations

from pathlib import Path


def test_app_build_default_go_version_matches_ecosystem_standard() -> None:
    workflow = Path(".github/workflows/app-build.yml").read_text()

    assert "go-version:" in workflow
    assert "default: '1.26.4'" in workflow


def test_app_build_exports_git_auth_for_child_package_fetches() -> None:
    workflow = Path(".github/workflows/app-build.yml").read_text()

    assert "GIT_CONFIG_COUNT=2" in workflow
    assert "GIT_ASKPASS=$RUNNER_TEMP/git-askpass.sh" in workflow
    assert "GIT_TERMINAL_PROMPT=0" in workflow
