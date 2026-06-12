from __future__ import annotations

from pathlib import Path


def test_app_build_default_go_version_matches_ecosystem_standard() -> None:
    workflow = Path(".github/workflows/app-build.yml").read_text()

    assert "go-version:" in workflow
    assert "default: '1.26.4'" in workflow

