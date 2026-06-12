from __future__ import annotations

from pathlib import Path


def test_app_build_default_go_version_matches_ecosystem_standard() -> None:
    workflow = Path(".github/workflows/app-build.yml").read_text()

    assert "go-version:" in workflow
    assert "default: '1.26.4'" in workflow


def test_app_build_default_flutter_version_matches_runner_image() -> None:
    workflow = Path(".github/workflows/app-build.yml").read_text()

    assert "flutter-version:" in workflow
    assert "default: '3.41.7'" in workflow
    assert "flutter-version: ${{ inputs['flutter-version'] }}" in workflow


def test_app_build_default_rust_version_matches_runner_image() -> None:
    workflow = Path(".github/workflows/app-build.yml").read_text()

    assert "rust-toolchain:" in workflow
    assert "default: '1.95.0'" in workflow
    assert "Configure writable Rustup home" in workflow
    assert "JOB_RUSTUP_HOME: ${{ runner.temp }}/rustup" in workflow
    assert "RUSTUP_HOME=$JOB_RUSTUP_HOME" in workflow
    assert "RUSTUP_HOME: ${{ runner.temp }}/rustup" in workflow
    assert "toolchain: ${{ inputs['rust-toolchain'] }}" in workflow


def test_app_build_exports_git_auth_for_child_package_fetches() -> None:
    workflow = Path(".github/workflows/app-build.yml").read_text()

    assert "GIT_CONFIG_COUNT=2" in workflow
    assert "GIT_ASKPASS=$RUNNER_TEMP/git-askpass.sh" in workflow
    assert "GIT_TERMINAL_PROMPT=0" in workflow
    assert "CARGO_NET_GIT_FETCH_WITH_CLI=true" in workflow


def test_reusable_workflows_allow_product_submodule_policy() -> None:
    app_build = Path(".github/workflows/app-build.yml").read_text()
    app_release = Path(".github/workflows/app-release.yml").read_text()

    assert "checkout-submodules:" in app_build
    assert "submodules: ${{ inputs['checkout-submodules'] }}" in app_build
    assert "checkout-submodules:" in app_release
    assert "checkout-submodules: ${{ inputs['checkout-submodules'] }}" in app_release
    assert "submodules: ${{ inputs['checkout-submodules'] }}" in app_release


def test_app_build_materializes_android_signing_only_for_android_rows() -> None:
    workflow = Path(".github/workflows/app-build.yml").read_text()

    assert "ANDROID_KEYSTORE_BASE64:" in workflow
    assert "ANDROID_KEYSTORE_PASSWORD:" in workflow
    assert "ANDROID_KEY_ALIAS:" in workflow
    assert "ANDROID_KEY_PASSWORD:" in workflow
    assert "Materialize Android release keystore" in workflow
    assert '*" android "*)' in workflow
    assert "Android signing is partially configured" in workflow
    assert "upload-keystore.jks" in workflow
    assert "android/key.properties" in workflow
    assert "storeFile=upload-keystore.jks" in workflow
