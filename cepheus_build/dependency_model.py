"""First-party dependency manifest and local override rendering.

The committed product manifests should be able to move away from recursive
first-party submodules. Local development still needs fast sibling checkouts,
so this module renders ignored override files from one shared manifest.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class FirstPartyPackage:
    repo: str
    package_path: str = "."

    def local_path(self, workspace_root: Path) -> Path:
        return (workspace_root / self.repo / self.package_path).resolve()


@dataclass(frozen=True)
class FlutterOverrides:
    pubspec: str
    packages: tuple[str, ...]


@dataclass(frozen=True)
class GoWorkspace:
    module_root: str
    modules: tuple[str, ...]


@dataclass(frozen=True)
class ProductDependencies:
    flutter: tuple[FlutterOverrides, ...] = ()
    go: tuple[GoWorkspace, ...] = ()
    allowed_submodule_paths: tuple[str, ...] = ()


@dataclass(frozen=True)
class DependencyOutput:
    path: Path
    content: str
    kind: str


@dataclass(frozen=True)
class DependencyAuditIssue:
    path: Path
    code: str
    message: str


@dataclass(frozen=True)
class _YamlDependencyBlock:
    section: str | None
    lines: list[str]


FLUTTER_PACKAGES: dict[str, FirstPartyPackage] = {
    "forge": FirstPartyPackage("forge"),
    "helm_client": FirstPartyPackage("helm", "sdks/dart"),
    "luxon": FirstPartyPackage("luxon", "clients/flutter"),
    "printdeck_app_mode": FirstPartyPackage("printdeck_app_mode"),
    "printdeck_color_composition": FirstPartyPackage("printdeck-color-composition", "clients/flutter"),
    "printdeck_command_palette": FirstPartyPackage("printdeck_command_palette"),
    "printdeck_cortex": FirstPartyPackage("cortex", "clients/flutter"),
    "printdeck_helm": FirstPartyPackage("helm", "clients/flutter"),
    "printdeck_identity": FirstPartyPackage("printdeck_identity"),
    "printdeck_ledger": FirstPartyPackage("ledger", "clients/flutter"),
    "printdeck_machines": FirstPartyPackage("machines", "clients/flutter"),
    "printdeck_marketplace": FirstPartyPackage("marketplace", "clients/flutter"),
    "printdeck_nexus": FirstPartyPackage("nexus", "clients/flutter"),
    "printdeck_notifications": FirstPartyPackage("notifications", "clients/flutter"),
    "printdeck_product_platform": FirstPartyPackage("printdeck_product_platform"),
    "printdeck_projects": FirstPartyPackage("projects", "clients/flutter"),
    "printdeck_setup": FirstPartyPackage("printdeck_setup"),
    "printdeck_slicer": FirstPartyPackage("slicer", "clients/flutter"),
    "printdeck_stockpile": FirstPartyPackage("stockpile", "clients/flutter"),
    "printdeck_tags": FirstPartyPackage("tags", "clients/flutter"),
    "printdeck_telescope": FirstPartyPackage("telescope", "clients/flutter"),
    "stockpile_client": FirstPartyPackage("stockpile", "sdks/dart"),
}


GO_MODULES: dict[str, FirstPartyPackage] = {
    "github.com/cepheuslabs/apiutil": FirstPartyPackage("apiutil"),
    "github.com/cepheuslabs/auth": FirstPartyPackage("auth"),
    "github.com/cepheuslabs/cortex": FirstPartyPackage("cortex"),
    "github.com/cepheuslabs/gcode": FirstPartyPackage("gcode"),
    "github.com/cepheuslabs/helm": FirstPartyPackage("helm"),
    "github.com/cepheuslabs/ledger": FirstPartyPackage("ledger"),
    "github.com/cepheuslabs/luxon": FirstPartyPackage("luxon"),
    "github.com/cepheuslabs/machines": FirstPartyPackage("machines"),
    "github.com/cepheuslabs/marketplace": FirstPartyPackage("marketplace"),
    "github.com/cepheuslabs/nexus": FirstPartyPackage("nexus"),
    "github.com/cepheuslabs/notifications": FirstPartyPackage("notifications"),
    "github.com/cepheuslabs/projects": FirstPartyPackage("projects"),
    "github.com/cepheuslabs/resolv": FirstPartyPackage("resolv"),
    "github.com/cepheuslabs/slicer": FirstPartyPackage("slicer"),
    "github.com/cepheuslabs/stockpile": FirstPartyPackage("stockpile"),
    "github.com/cepheuslabs/tags": FirstPartyPackage("tags"),
    "github.com/cepheuslabs/telescope": FirstPartyPackage("telescope"),
    "github.com/cepheuslabs/threemf": FirstPartyPackage("threemf"),
}


PRINTDECK_FRONTEND_PACKAGES = (
    "forge",
    "helm_client",
    "luxon",
    "printdeck_app_mode",
    "printdeck_command_palette",
    "printdeck_cortex",
    "printdeck_helm",
    "printdeck_ledger",
    "printdeck_machines",
    "printdeck_marketplace",
    "printdeck_nexus",
    "printdeck_notifications",
    "printdeck_product_platform",
    "printdeck_projects",
    "printdeck_slicer",
    "printdeck_stockpile",
    "printdeck_tags",
    "printdeck_telescope",
    "stockpile_client",
)


PRODUCT_DEPENDENCIES: dict[str, ProductDependencies] = {
    "printdeck": ProductDependencies(
        flutter=(
            FlutterOverrides(
                pubspec="frontend/pubspec.yaml",
                packages=PRINTDECK_FRONTEND_PACKAGES,
            ),
        ),
        go=(
            GoWorkspace(
                module_root="backend",
                modules=tuple(GO_MODULES),
            ),
        ),
        allowed_submodule_paths=(
            "shared/cepheus-build",
            "third_party/printdeck-ecosystem-contracts",
        ),
    ),
    "anvil": ProductDependencies(
        flutter=(
            FlutterOverrides(
                pubspec="app/pubspec.yaml",
                packages=(
                    "forge",
                    "printdeck_app_mode",
                    "printdeck_color_composition",
                    "printdeck_command_palette",
                    "printdeck_cortex",
                    "printdeck_identity",
                    "printdeck_machines",
                    "printdeck_marketplace",
                    "printdeck_nexus",
                    "printdeck_notifications",
                    "printdeck_product_platform",
                    "printdeck_projects",
                    "printdeck_setup",
                    "printdeck_stockpile",
                    "printdeck_tags",
                    "printdeck_telescope",
                ),
            ),
        ),
        allowed_submodule_paths=(
            "shared/cepheus-build",
            "shared/gcode",
            "shared/printdeck/ecosystem_contracts",
            "shared/printdeck/rust-contracts",
            "shared/printdeck/slicer-core",
        ),
    ),
    "colorwake-studio": ProductDependencies(
        flutter=(
            FlutterOverrides(
                pubspec="apps/colorwake_studio/pubspec.yaml",
                packages=(
                    "forge",
                    "printdeck_app_mode",
                    "printdeck_command_palette",
                    "printdeck_identity",
                    "printdeck_machines",
                    "printdeck_marketplace",
                    "printdeck_product_platform",
                    "printdeck_setup",
                    "printdeck_stockpile",
                    "printdeck_telescope",
                ),
            ),
        ),
        allowed_submodule_paths=(
            "shared/cepheus-build",
            "shared/printdeck/color-composition",
            "shared/printdeck/color-model",
            "shared/printdeck/ecosystem_contracts",
            "shared/printdeck/rust-contracts",
            "shared/threemf",
        ),
    ),
    "deckhand": ProductDependencies(
        flutter=(
            FlutterOverrides(
                pubspec="app/pubspec.yaml",
                packages=("printdeck_product_platform", "printdeck_telescope"),
            ),
            FlutterOverrides(
                pubspec="packages/deckhand_ui/pubspec.yaml",
                packages=("printdeck_product_platform",),
            ),
        ),
    ),
    "foundry": ProductDependencies(
        flutter=(
            FlutterOverrides(
                pubspec="apps/setup_ui_flutter/pubspec.yaml",
                packages=("forge", "printdeck_product_platform"),
            ),
        ),
        allowed_submodule_paths=(
            "marketplace/printdeck",
            "shared/cepheus-build",
            "shared/printdeck/ecosystem_contracts",
            "shared/printdeck/rust-contracts",
        ),
    ),
}


def relpath(from_dir: Path, to_path: Path) -> str:
    path = os.path.relpath(to_path, start=from_dir)
    return "." if path == "." else path.replace(os.sep, "/")


def render_flutter_overrides(
    *,
    product: str,
    repo_root: Path,
    workspace_root: Path,
    target: FlutterOverrides,
) -> DependencyOutput:
    pubspec_path = (repo_root / target.pubspec).resolve()
    output_path = pubspec_path.with_name("pubspec_overrides.yaml")
    pubspec_dir = pubspec_path.parent
    lines = [
        "# Generated by `cepheus-build deps --write`.",
        "# Local-only sibling checkout overrides. Do not commit.",
        "dependency_overrides:",
    ]
    for package_name in target.packages:
        package = FLUTTER_PACKAGES[package_name]
        package_path = package.local_path(workspace_root)
        lines.extend(
            [
                f"  {package_name}:",
                f"    path: {relpath(pubspec_dir, package_path)}",
            ]
        )
    return DependencyOutput(path=output_path, content="\n".join(lines) + "\n", kind=f"{product}:flutter")


def render_go_work(
    *,
    product: str,
    repo_root: Path,
    workspace_root: Path,
    target: GoWorkspace,
) -> DependencyOutput:
    module_root = (repo_root / target.module_root).resolve()
    output_path = module_root / "go.work"
    module_paths = [module_root]
    module_paths.extend(GO_MODULES[module].local_path(workspace_root) for module in target.modules)
    lines = [
        "// Generated by `cepheus-build deps --write`.",
        "// Local-only sibling checkout workspace. Do not commit.",
        "go 1.26.4",
        "",
        "use (",
    ]
    lines.extend(f"\t{relpath(module_root, path)}" for path in module_paths)
    lines.append(")")
    return DependencyOutput(path=output_path, content="\n".join(lines) + "\n", kind=f"{product}:go")


def dependency_outputs(product: str, repo_root: Path, workspace_root: Path) -> list[DependencyOutput]:
    try:
        deps = PRODUCT_DEPENDENCIES[product]
    except KeyError as exc:
        supported = ", ".join(sorted(PRODUCT_DEPENDENCIES))
        raise KeyError(f"unsupported dependency product '{product}' (supported: {supported})") from exc

    outputs: list[DependencyOutput] = []
    outputs.extend(
        render_flutter_overrides(
            product=product,
            repo_root=repo_root,
            workspace_root=workspace_root,
            target=target,
        )
        for target in deps.flutter
    )
    outputs.extend(
        render_go_work(
            product=product,
            repo_root=repo_root,
            workspace_root=workspace_root,
            target=target,
        )
        for target in deps.go
    )
    return outputs


def missing_local_paths(product: str, workspace_root: Path) -> list[Path]:
    deps = PRODUCT_DEPENDENCIES[product]
    packages: set[FirstPartyPackage] = set()
    for target in deps.flutter:
        packages.update(FLUTTER_PACKAGES[name] for name in target.packages)
    for target in deps.go:
        packages.update(GO_MODULES[name] for name in target.modules)
    return sorted(package.local_path(workspace_root) for package in packages if not package.local_path(workspace_root).exists())


def dependency_audit_issues(product: str, repo_root: Path) -> list[DependencyAuditIssue]:
    try:
        deps = PRODUCT_DEPENDENCIES[product]
    except KeyError as exc:
        supported = ", ".join(sorted(PRODUCT_DEPENDENCIES))
        raise KeyError(f"unsupported dependency product '{product}' (supported: {supported})") from exc

    issues: list[DependencyAuditIssue] = []
    for target in deps.flutter:
        issues.extend(_audit_flutter_manifest(repo_root / target.pubspec, target.packages))
    for target in deps.go:
        issues.extend(_audit_go_mod(repo_root / target.module_root / "go.mod", target.modules))
    issues.extend(_audit_gitmodules(repo_root / ".gitmodules", deps.allowed_submodule_paths))
    return issues


def _audit_flutter_manifest(pubspec_path: Path, package_names: tuple[str, ...]) -> list[DependencyAuditIssue]:
    if not pubspec_path.exists():
        return []

    lines = pubspec_path.read_text().splitlines()
    issues: list[DependencyAuditIssue] = []
    for package_name in package_names:
        for block in _yaml_dependency_blocks(lines, package_name):
            block_text = "\n".join(block.lines)
            if block.section == "dependency_overrides":
                issues.append(
                    DependencyAuditIssue(
                        path=pubspec_path,
                        code="first_party_flutter_dependency_override",
                        message=f"{package_name} is committed under dependency_overrides; use generated pubspec_overrides.yaml for sibling checkouts",
                    )
                )
                continue
            if _yaml_block_has_immediate_key(block.lines, "path"):
                issues.append(
                    DependencyAuditIssue(
                        path=pubspec_path,
                        code="first_party_flutter_path_dependency",
                        message=f"{package_name} uses a committed path dependency; use a pinned git ref in pubspec.yaml and local pubspec_overrides.yaml for sibling checkouts",
                    )
                )
            if _yaml_block_has_key(block.lines, "git") and not _yaml_block_has_key(block.lines, "ref"):
                issues.append(
                    DependencyAuditIssue(
                        path=pubspec_path,
                        code="first_party_flutter_unpinned_git_dependency",
                        message=f"{package_name} uses git without an explicit ref",
                    )
                )
            if "pubspec_overrides.yaml" in block_text:
                issues.append(
                    DependencyAuditIssue(
                        path=pubspec_path,
                        code="first_party_flutter_override_reference",
                        message=f"{package_name} references pubspec_overrides.yaml from a committed manifest",
                    )
                )
    return issues


def _yaml_dependency_blocks(lines: list[str], package_name: str) -> list[_YamlDependencyBlock]:
    blocks: list[_YamlDependencyBlock] = []
    current_section: str | None = None
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if current_section not in {"dependencies", "dev_dependencies", "dependency_overrides"}:
            if indent == 0 and ":" in stripped:
                current_section = stripped.split(":", 1)[0]
            continue
        if not stripped.startswith(f"{package_name}:"):
            if indent == 0 and ":" in stripped:
                current_section = stripped.split(":", 1)[0]
            continue
        block = [line]
        for child in lines[index + 1 :]:
            child_stripped = child.strip()
            if not child_stripped or child_stripped.startswith("#"):
                block.append(child)
                continue
            child_indent = len(child) - len(child.lstrip())
            if child_indent <= indent:
                break
            block.append(child)
        blocks.append(_YamlDependencyBlock(section=current_section, lines=block))
    return blocks


def _yaml_block_has_key(block: list[str], key: str) -> bool:
    return any(line.strip().startswith(f"{key}:") for line in block)


def _yaml_block_has_immediate_key(block: list[str], key: str) -> bool:
    if not block:
        return False
    root_indent = len(block[0]) - len(block[0].lstrip())
    child_indents = [
        len(line) - len(line.lstrip())
        for line in block[1:]
        if line.strip() and not line.strip().startswith("#") and len(line) - len(line.lstrip()) > root_indent
    ]
    if not child_indents:
        return False
    immediate_indent = min(child_indents)
    return any(
        line.strip().startswith(f"{key}:")
        and len(line) - len(line.lstrip()) == immediate_indent
        for line in block[1:]
    )


def _audit_go_mod(go_mod_path: Path, module_names: tuple[str, ...]) -> list[DependencyAuditIssue]:
    if not go_mod_path.exists():
        return []

    first_party_modules = set(module_names)
    issues: list[DependencyAuditIssue] = []
    for line in go_mod_path.read_text().splitlines():
        stripped = line.strip()
        if "=>" not in stripped or stripped.startswith("//"):
            continue
        left, right = stripped.split("=>", 1)
        left = left.removeprefix("replace").strip()
        module = left.split()[0] if left.split() else ""
        replacement = right.strip().split()[0] if right.strip().split() else ""
        if module in first_party_modules and _is_local_path(replacement):
            issues.append(
                DependencyAuditIssue(
                    path=go_mod_path,
                    code="first_party_go_local_replace",
                    message=f"{module} uses a committed local replace; use a pinned module version and generated go.work for sibling checkouts",
                )
            )
    return issues


def _is_local_path(value: str) -> bool:
    return value.startswith(".") or value.startswith("/") or value.startswith("~")


def _audit_gitmodules(gitmodules_path: Path, allowed_paths: tuple[str, ...]) -> list[DependencyAuditIssue]:
    if not gitmodules_path.exists():
        return []

    allowed = set(allowed_paths)
    issues: list[DependencyAuditIssue] = []
    for submodule in _parse_gitmodules(gitmodules_path):
        path = submodule.get("path", "")
        url = submodule.get("url", "")
        if path and _is_cepheus_submodule_url(url) and path not in allowed:
            issues.append(
                DependencyAuditIssue(
                    path=gitmodules_path,
                    code="unexpected_first_party_submodule",
                    message=f"{path} is a Cepheus first-party submodule but is not in the product allowlist",
                )
            )
    return issues


def _parse_gitmodules(gitmodules_path: Path) -> list[dict[str, str]]:
    submodules: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for line in gitmodules_path.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("[submodule "):
            if current:
                submodules.append(current)
            current = {}
            continue
        if current is not None and "=" in stripped:
            key, value = stripped.split("=", 1)
            current[key.strip()] = value.strip()
    if current:
        submodules.append(current)
    return submodules


def _is_cepheus_submodule_url(url: str) -> bool:
    return (
        url.startswith("../")
        or "github.com/CepheusLabs/" in url
        or "github.com/cepheuslabs/" in url
    )
