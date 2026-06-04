from __future__ import annotations

from pathlib import Path

from cepheus_build.commands import _deps_repo_root
from cepheus_build.config import ProductConfig
from cepheus_build.dependency_model import dependency_outputs, missing_local_paths


def test_printdeck_outputs_flutter_and_go_files(tmp_path: Path) -> None:
    repo_root = tmp_path / "printdeck"
    workspace_root = tmp_path

    outputs = dependency_outputs("printdeck", repo_root, workspace_root)

    paths = {output.path.relative_to(repo_root).as_posix() for output in outputs}
    assert paths == {"frontend/pubspec_overrides.yaml", "backend/go.work"}


def test_printdeck_flutter_override_uses_sibling_checkout_paths(tmp_path: Path) -> None:
    output = next(
        output
        for output in dependency_outputs("printdeck", tmp_path / "printdeck", tmp_path)
        if output.path.name == "pubspec_overrides.yaml"
    )

    assert "dependency_overrides:" in output.content
    assert "  forge:\n    path: ../../forge\n" in output.content
    assert "  printdeck_helm:\n    path: ../../helm/clients/flutter\n" in output.content
    assert "  stockpile_client:\n    path: ../../stockpile/sdks/dart\n" in output.content


def test_printdeck_go_work_uses_sibling_module_paths(tmp_path: Path) -> None:
    output = next(
        output
        for output in dependency_outputs("printdeck", tmp_path / "printdeck", tmp_path)
        if output.path.name == "go.work"
    )

    assert "go 1.26.4" in output.content
    assert "\t.\n" in output.content
    assert "\t../../apiutil\n" in output.content
    assert "\t../../helm\n" in output.content
    assert "\t../../threemf\n" in output.content


def test_missing_local_paths_reports_absent_package_roots(tmp_path: Path) -> None:
    missing = missing_local_paths("foundry", tmp_path)

    assert tmp_path / "forge" in missing
    assert tmp_path / "printdeck_product_platform" in missing


def test_deps_repo_root_prefers_workspace_product_checkout(tmp_path: Path) -> None:
    workspace_root = tmp_path
    product_root = workspace_root / "colorwake-studio"
    config_dir = product_root / "shared" / "cepheus-build" / "products"
    config_dir.mkdir(parents=True)
    product_root.mkdir(exist_ok=True)
    config = ProductConfig(
        path=config_dir / "colorwake-studio.toml",
        data={
            "product": {
                "slug": "colorwake-studio",
                "repo_root": "../../colorwake-studio",
            }
        },
    )

    assert _deps_repo_root(config, workspace_root) == product_root.resolve()
