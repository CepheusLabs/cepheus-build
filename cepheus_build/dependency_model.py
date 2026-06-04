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


@dataclass(frozen=True)
class DependencyOutput:
    path: Path
    content: str
    kind: str


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
