from __future__ import annotations

from pathlib import Path

from cepheus_build.commands import _deps_repo_root
from cepheus_build.config import ProductConfig
from cepheus_build.dependency_model import (
    dependency_audit_issues,
    dependency_outputs,
    missing_local_paths,
)


def test_printdeck_app_outputs_root_flutter_overrides_only(tmp_path: Path) -> None:
    repo_root = tmp_path / "printdeck-app"
    workspace_root = tmp_path

    outputs = dependency_outputs("printdeck-app", repo_root, workspace_root)

    paths = {output.path.relative_to(repo_root).as_posix() for output in outputs}
    assert paths == {"pubspec_overrides.yaml"}


def test_printdeck_server_outputs_root_go_work_only(tmp_path: Path) -> None:
    repo_root = tmp_path / "printdeck-server"
    workspace_root = tmp_path

    outputs = dependency_outputs("printdeck-server", repo_root, workspace_root)

    paths = {output.path.relative_to(repo_root).as_posix() for output in outputs}
    assert paths == {"go.work"}


def test_printdeck_agent_has_no_override_outputs(tmp_path: Path) -> None:
    outputs = dependency_outputs("printdeck-agent", tmp_path / "printdeck-agent", tmp_path)

    assert outputs == []


def test_cepheus_build_output_uses_sibling_forge_path(tmp_path: Path) -> None:
    output = dependency_outputs("cepheus-build", tmp_path / "cepheus-build", tmp_path)[0]

    assert output.path.relative_to(tmp_path / "cepheus-build").as_posix() == "app/pubspec_overrides.yaml"
    assert "  forge:\n    path: ../../forge\n" in output.content


def test_printdeck_app_flutter_override_uses_sibling_checkout_paths(tmp_path: Path) -> None:
    output = next(
        output
        for output in dependency_outputs("printdeck-app", tmp_path / "printdeck-app", tmp_path)
        if output.path.name == "pubspec_overrides.yaml"
    )

    # The pubspec sits at the repo root, so siblings are one level up.
    assert "dependency_overrides:" in output.content
    assert "  forge:\n    path: ../forge\n" in output.content
    assert "  printdeck_helm:\n    path: ../helm/clients/flutter\n" in output.content
    assert "  stockpile_client:\n    path: ../stockpile/sdks/dart\n" in output.content


def test_printdeck_server_go_work_uses_sibling_module_paths(tmp_path: Path) -> None:
    output = next(
        output
        for output in dependency_outputs("printdeck-server", tmp_path / "printdeck-server", tmp_path)
        if output.path.name == "go.work"
    )

    # The module root is the repo root, so siblings are one level up.
    assert "go 1.26.4" in output.content
    assert "\t.\n" in output.content
    assert "\t../apiutil\n" in output.content
    assert "\t../helm\n" in output.content
    assert "\t../threemf\n" in output.content


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


def test_dependency_audit_accepts_printdeck_app_committed_model(tmp_path: Path) -> None:
    repo_root = tmp_path / "printdeck-app"
    _write_printdeck_app_manifests(repo_root)

    assert dependency_audit_issues("printdeck-app", repo_root) == []


def test_dependency_audit_accepts_printdeck_server_committed_model(tmp_path: Path) -> None:
    repo_root = tmp_path / "printdeck-server"
    _write_printdeck_server_manifests(repo_root)

    assert dependency_audit_issues("printdeck-server", repo_root) == []


def test_dependency_audit_rejects_committed_flutter_path_dependency(tmp_path: Path) -> None:
    repo_root = tmp_path / "printdeck-app"
    _write_printdeck_app_manifests(
        repo_root,
        pubspec_dependency="""
  printdeck_stockpile:
    path: ../stockpile/clients/flutter
""",
    )

    issues = dependency_audit_issues("printdeck-app", repo_root)

    assert [issue.code for issue in issues] == ["first_party_flutter_path_dependency"]


def test_dependency_audit_rejects_unpinned_flutter_git_dependency(tmp_path: Path) -> None:
    repo_root = tmp_path / "printdeck-app"
    _write_printdeck_app_manifests(
        repo_root,
        pubspec_dependency="""
  printdeck_stockpile:
    git:
      url: https://github.com/CepheusLabs/stockpile.git
      path: clients/flutter
""",
    )

    issues = dependency_audit_issues("printdeck-app", repo_root)

    assert [issue.code for issue in issues] == ["first_party_flutter_unpinned_git_dependency"]


def test_dependency_audit_rejects_committed_first_party_dependency_overrides(tmp_path: Path) -> None:
    cases = (
        ("anvil", "app/pubspec.yaml"),
        ("colorwake-studio", "apps/colorwake_studio/pubspec.yaml"),
    )
    for product, pubspec in cases:
        repo_root = tmp_path / product
        pubspec_path = repo_root / pubspec
        pubspec_path.parent.mkdir(parents=True)
        pubspec_path.write_text(
            """
name: app
dependencies:
  forge:
    git:
      url: https://github.com/CepheusLabs/forge.git
      ref: 0000000000000000000000000000000000000000
dependency_overrides:
  forge:
    path: ../../forge
""".lstrip()
        )

        issues = dependency_audit_issues(product, repo_root)

        assert [issue.code for issue in issues] == ["first_party_flutter_dependency_override"]


def test_dependency_audit_rejects_committed_go_local_replace(tmp_path: Path) -> None:
    repo_root = tmp_path / "printdeck-server"
    _write_printdeck_server_manifests(
        repo_root,
        go_replace="replace github.com/cepheuslabs/stockpile => ../stockpile",
    )

    issues = dependency_audit_issues("printdeck-server", repo_root)

    assert [issue.code for issue in issues] == ["first_party_go_local_replace"]


def test_dependency_audit_rejects_first_party_submodule(tmp_path: Path) -> None:
    repo_root = tmp_path / "printdeck-app"
    _write_printdeck_app_manifests(
        repo_root,
        extra_gitmodule="""
[submodule "packages/stockpile"]
\tpath = packages/stockpile
\turl = https://github.com/CepheusLabs/stockpile.git
""",
    )

    issues = dependency_audit_issues("printdeck-app", repo_root)

    assert [issue.code for issue in issues] == ["first_party_submodule"]


def _write_printdeck_app_manifests(
    repo_root: Path,
    *,
    pubspec_dependency: str = """
  printdeck_stockpile:
    git:
      url: https://github.com/CepheusLabs/stockpile.git
      ref: 0000000000000000000000000000000000000000
      path: clients/flutter
""",
    extra_gitmodule: str = "",
) -> None:
    repo_root.mkdir(parents=True)
    (repo_root / "pubspec.yaml").write_text(
        "name: printdeck\n"
        "dependencies:\n"
        f"{pubspec_dependency.lstrip()}"
    )
    if extra_gitmodule:
        (repo_root / ".gitmodules").write_text(extra_gitmodule)


def _write_printdeck_server_manifests(
    repo_root: Path,
    *,
    go_replace: str = "",
) -> None:
    repo_root.mkdir(parents=True)
    (repo_root / "go.mod").write_text(
        "module github.com/CepheusLabs/printdeck-server\n\n"
        "require github.com/cepheuslabs/stockpile v0.2.1\n"
        f"{go_replace}\n"
    )
