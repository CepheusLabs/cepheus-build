from __future__ import annotations

from pathlib import Path

from cepheus_build.config import ProductConfig, load_toml


def _printdeck_config() -> ProductConfig:
    path = Path(__file__).resolve().parents[1] / "products" / "printdeck.toml"
    return ProductConfig(path=path, data=load_toml(path))


def test_printdeck_windows_target_uses_repo_local_powershell_build() -> None:
    target = _printdeck_config().target("windows")

    assert target["commands"] == [
        'pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/build_windows.ps1 '
        '-BuildName "%CBUILD_VERSION%" -BuildNumber "%CBUILD_BUILD_NUMBER%"'
    ]
    assert "make" not in target["tools"]
    assert {"flutter", "pwsh", "cmake", "ninja"}.issubset(set(target["tools"]))


def test_printdeck_server_group_uses_compose_target() -> None:
    config = _printdeck_config()

    assert config.expand_targets(["server"]) == ["server-compose"]

    target = config.target("server-compose")
    assert target["hosts"] == ["linux"]
    assert target["cwd"] == "."
    assert target["commands"] == [
        'bash "$CBUILD_TOOL_ROOT/scripts/printdeck-server-compose.sh"'
    ]
    assert {"bash", "docker", "docker-daemon"}.issubset(set(target["tools"]))
