"""Pin-lint: assert the build-env toolchain pins never drift across the pool.

The root failure mode this guards is VERSION DRIFT: a `brew`/`choco` "latest"
install on one VM races ahead of the pinned Linux image and breaks shared code
(a real incident: Flutter 3.44.2 vs the pinned 3.41.7). docker/versions.env is
the single source of truth; this test asserts:

  (a) versions.env parses and carries every CBUILD_*_VERSION key,
  (b) the Linux Dockerfile ARGs equal the manifest (Go/Rust/Flutter),
  (c) the manifest versions appear in provision.sh and install.bat (so the
      provisioners stay in lockstep with the manifest),
  (d) no unpinned `brew install`/`choco install` of go/golang/cocoapods/
      python3 sneaks back in (catches future drift at its source).

Modeled on tests/test_gopins.py (pure logic, repo-file driven).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
DOCKER = REPO_ROOT / "docker"
VERSIONS_ENV = DOCKER / "versions.env"
LINUX_DOCKERFILE = DOCKER / "linux" / "Dockerfile"
MACOS_PROVISION = DOCKER / "macos" / "provision.sh"
WINDOWS_INSTALL = DOCKER / "windows" / "oem" / "install.bat"

REQUIRED_KEYS = (
    "CBUILD_FLUTTER_VERSION",
    "CBUILD_GO_VERSION",
    "CBUILD_RUST_VERSION",
    "CBUILD_COCOAPODS_VERSION",
    "CBUILD_PYTHON_VERSION",
    "CBUILD_JDK_MAJOR",
)


def parse_versions_env(text: str) -> dict[str, str]:
    """Parse a plain KEY=VALUE manifest (skip blanks/comments). No quotes."""
    out: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        out[key.strip()] = value.strip()
    return out


@pytest.fixture(scope="module")
def manifest() -> dict[str, str]:
    return parse_versions_env(VERSIONS_ENV.read_text(encoding="utf-8"))


def test_versions_env_exists_and_has_all_keys(manifest: dict[str, str]) -> None:
    assert VERSIONS_ENV.exists(), "docker/versions.env is the single source of truth"
    missing = [key for key in REQUIRED_KEYS if key not in manifest]
    assert not missing, f"versions.env missing keys: {missing}"
    for key in REQUIRED_KEYS:
        assert manifest[key], f"{key} must have a non-empty value"


def test_versions_env_values_are_bare(manifest: dict[str, str]) -> None:
    # Both POSIX `source` and the Windows `for /f` parser need quote-free values.
    for key, value in manifest.items():
        assert '"' not in value and "'" not in value and " " not in value, (
            f"{key}={value!r} must be a bare KEY=VALUE token"
        )


def _dockerfile_args() -> dict[str, str]:
    args: dict[str, str] = {}
    for match in re.finditer(
        r"^ARG\s+(\w+)=(\S+)", LINUX_DOCKERFILE.read_text(encoding="utf-8"), re.MULTILINE
    ):
        args[match.group(1)] = match.group(2)
    return args


def test_dockerfile_args_equal_manifest(manifest: dict[str, str]) -> None:
    args = _dockerfile_args()
    pairs = {
        "GO_VERSION": "CBUILD_GO_VERSION",
        "RUST_VERSION": "CBUILD_RUST_VERSION",
        "FLUTTER_VERSION": "CBUILD_FLUTTER_VERSION",
    }
    for arg_name, manifest_key in pairs.items():
        assert args.get(arg_name) == manifest[manifest_key], (
            f"Dockerfile ARG {arg_name}={args.get(arg_name)} drifted from "
            f"versions.env {manifest_key}={manifest[manifest_key]}"
        )


def test_manifest_versions_appear_in_macos_provision(manifest: dict[str, str]) -> None:
    # provision.sh sources versions.env, but the version strings must also be
    # referenced (Flutter fallback) so a stale pin is visible at review time.
    text = MACOS_PROVISION.read_text(encoding="utf-8")
    assert "versions.env" in text, "provision.sh must source the manifest"
    assert manifest["CBUILD_FLUTTER_VERSION"] in text


def test_manifest_versions_appear_in_windows_install(manifest: dict[str, str]) -> None:
    # install.bat re-declares the pins (the oem dir excludes versions.env), so
    # the literal versions MUST appear and equal the manifest.
    text = WINDOWS_INSTALL.read_text(encoding="utf-8")
    for key in (
        "CBUILD_FLUTTER_VERSION",
        "CBUILD_GO_VERSION",
        "CBUILD_RUST_VERSION",
        "CBUILD_PYTHON_VERSION",
    ):
        assert f'set "{key}={manifest[key]}"' in text, (
            f"install.bat must re-declare {key}={manifest[key]} (in sync with versions.env)"
        )


# Drift gate: a package-manager install line that mentions one of these tools
# WITHOUT a version/pin on or near it is a regression.
_PINNED_TOKENS = ("--version", "-v ", "-v=", "git clone", "rustup", "win.rustup")


def _install_lines(text: str, installer: str) -> list[str]:
    return [line for line in text.splitlines() if installer in line and "install" in line]


@pytest.mark.parametrize("tool", ["go", "golang", "cocoapods", "python3"])
def test_no_unpinned_brew_install(tool: str) -> None:
    text = MACOS_PROVISION.read_text(encoding="utf-8")
    for line in _install_lines(text, "brew install"):
        # Match the tool as a whole word in the brew install line.
        if re.search(rf"\b{re.escape(tool)}\b", line):
            pytest.fail(
                f"unpinned `brew install ... {tool}` in provision.sh: {line.strip()!r} "
                f"-- brew floats to latest; pin it (download/gem/git-clone)."
            )


@pytest.mark.parametrize("tool", ["go", "golang", "cocoapods", "python3"])
def test_no_unpinned_choco_install(tool: str) -> None:
    text = WINDOWS_INSTALL.read_text(encoding="utf-8")
    for line in _install_lines(text, "choco.exe install"):
        if re.search(rf"\b{re.escape(tool)}\b", line):
            assert any(token in line for token in _PINNED_TOKENS), (
                f"unpinned `choco install ... {tool}` in install.bat: {line.strip()!r} "
                f"-- choco floats to latest; add --version=%CBUILD_{tool.upper()}_VERSION%."
            )
