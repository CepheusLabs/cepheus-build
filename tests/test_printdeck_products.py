from __future__ import annotations

from pathlib import Path

from cepheus_build.config import ProductConfig, load_toml

PRODUCTS_DIR = Path(__file__).resolve().parents[1] / "products"


def _load(name: str) -> ProductConfig:
    path = PRODUCTS_DIR / f"{name}.toml"
    return ProductConfig(path=path, data=load_toml(path))


def test_printdeck_app_windows_target_uses_repo_local_powershell_build() -> None:
    target = _load("printdeck-app").target("windows")

    assert target["commands"] == [
        'pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build_windows.ps1 '
        '-BuildName "%CBUILD_VERSION%" -BuildNumber "%CBUILD_BUILD_NUMBER%"'
    ]
    assert "make" not in target["tools"]
    assert {"flutter", "pwsh", "cmake", "ninja"}.issubset(set(target["tools"]))


def test_printdeck_app_targets_run_at_repo_root() -> None:
    # The split app repo is the old monorepo frontend/ promoted to the root:
    # nothing may keep pointing one directory down.
    config = _load("printdeck-app")

    for name in config.targets:
        target = config.target(name)
        assert target.get("cwd", ".") == ".", f"target {name} must run at the repo root"
        for artifact in target.get("artifacts", []):
            assert not artifact.startswith("frontend/"), (
                f"target {name} artifact {artifact} references the archived monorepo layout"
            )


def test_printdeck_app_has_no_server_surface() -> None:
    config = _load("printdeck-app")

    assert "server" not in config.groups
    assert "server-compose" not in config.targets


def test_printdeck_server_compose_target() -> None:
    target = _load("printdeck-server").target("compose")

    assert target["hosts"] == ["linux"]
    assert target["cwd"] == "."
    assert target["commands"] == [
        'bash "$CBUILD_TOOL_ROOT/scripts/printdeck-server-compose.sh"'
    ]
    assert {"bash", "docker", "docker-daemon"}.issubset(set(target["tools"]))


def test_printdeck_server_quality_groups_exclude_compose() -> None:
    config = _load("printdeck-server")

    assert config.expand_targets(["quality"]) == ["build", "vet", "test"]
    assert "compose" not in config.expand_targets(["all"])


def test_printdeck_agent_quality_targets() -> None:
    config = _load("printdeck-agent")

    assert config.expand_targets(["quality"]) == ["build", "vet", "test"]
    for name in ("build", "vet", "test"):
        target = config.target(name)
        assert target["cwd"] == "."
        assert target["tools"] == ["go"]
