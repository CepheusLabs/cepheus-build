"""Command-line driver for shared Cepheus Labs app builds."""

from __future__ import annotations

import argparse
import subprocess
import sys

from . import __version__
from .commands import (
    cmd_artifacts,
    cmd_build,
    cmd_ci_matrix,
    cmd_deploy,
    cmd_deps,
    cmd_describe,
    cmd_doctor,
    cmd_install_deps,
    cmd_list,
    cmd_local_sweep,
    cmd_plan,
    cmd_stamp,
    cmd_validate,
)
from .errors import BuildError
from .github import runner_profile_names
from .process import augment_process_path, set_color_enabled


def add_product_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("-p", "--product", help="Product name from products/<name>.toml.")
    parser.add_argument("-c", "--config", help="Path to a product config TOML file.")
    parser.add_argument("--repo-root", help="Override product.repo_root. Useful in CI.")


def add_json_arg(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit machine-readable JSON instead of human-readable text.",
    )


def add_local_build_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--mode", choices=["release", "profile", "debug"], default="release")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without running them.")
    parser.add_argument(
        "--skip-unsupported",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Skip targets that need another host OS. Defaults to true.",
    )
    parser.add_argument(
        "--flutter-arg",
        action="append",
        default=[],
        help="Additional raw argument to pass to default Flutter build targets. Repeat as needed.",
    )
    parser.add_argument(
        "--buildroot-dir",
        default="",
        help="Optional Buildroot checkout path for Foundry targets or workflow dispatch.",
    )
    parser.add_argument(
        "--check-tools",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Check target tools before local command execution. Defaults to true.",
    )
    parser.add_argument(
        "--install-missing-deps",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Install configured missing local tools before building. Defaults to false.",
    )
    parser.add_argument(
        "--keep-going",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Continue with later targets after one target fails. Defaults to true.",
    )
    parser.add_argument(
        "--no-sync",
        dest="no_sync",
        action="store_true",
        help="Skip syncing (git pull + submodule update) the product checkout before building.",
    )
    parser.add_argument(
        "--require-clean",
        dest="require_clean",
        action="store_true",
        help="Abort if the product working tree has uncommitted changes.",
    )


def add_github_build_args(parser: argparse.ArgumentParser) -> None:
    profiles = runner_profile_names()
    parser.add_argument(
        "--runner-profile",
        choices=profiles or None,
        default=profiles[0] if profiles else "github-hosted",
        help="Runner profile from build.toml.",
    )
    parser.add_argument("--github-repo", default="", help="Override [github].repository or detected origin.")
    parser.add_argument("--github-workflow", default="", help="Override [github].workflow or build.toml default.")
    parser.add_argument(
        "--planner-runner-json",
        default="",
        help="Override the JSON runs-on value for the planning job.",
    )
    parser.add_argument(
        "--setup-buildroot-deps",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Install Buildroot dependencies in GitHub workflows when the matrix requires them.",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="cepheus-build")
    parser.add_argument(
        "--version",
        action="version",
        version=f"cepheus-build {__version__}",
    )
    parser.add_argument(
        "--no-color",
        dest="no_color",
        action="store_true",
        help="Disable ANSI colour in output (also honours the NO_COLOR env var).",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    list_parser = sub.add_parser("list", help="List known shared product configs.")
    add_json_arg(list_parser)
    list_parser.set_defaults(func=cmd_list)

    plan = sub.add_parser("plan", help="Show the build plan for one product.")
    add_product_args(plan)
    plan.add_argument("targets", nargs="*", help="Targets or groups. Defaults to desktop.")
    add_json_arg(plan)
    plan.set_defaults(func=cmd_plan)

    stamp = sub.add_parser("stamp", help="Print the resolved version stamp.")
    add_product_args(stamp)
    stamp.add_argument("--github-output", action="store_true", help="Print key=value lines for GitHub outputs.")
    add_json_arg(stamp)
    stamp.set_defaults(func=cmd_stamp)

    describe = sub.add_parser("describe", help="Emit JSON describing products or one product.")
    add_product_args(describe)
    add_json_arg(describe)
    describe.set_defaults(func=cmd_describe)

    validate = sub.add_parser(
        "validate",
        help="Validate product config(s) against the product schema.",
    )
    add_product_args(validate)
    add_json_arg(validate)
    validate.set_defaults(func=cmd_validate)

    doctor = sub.add_parser("doctor", help="Check product paths and target tools.")
    add_product_args(doctor)
    doctor.add_argument("targets", nargs="*", help="Targets or groups. Defaults to desktop.")
    add_json_arg(doctor)
    doctor.set_defaults(func=cmd_doctor)

    install_deps = sub.add_parser("install-deps", help="Install configured local dependencies for product targets.")
    add_product_args(install_deps)
    install_deps.add_argument("targets", nargs="*", help="Targets or groups. Defaults to desktop.")
    install_deps.add_argument("--dry-run", action="store_true", help="Print install commands without running them.")
    install_deps.add_argument(
        "--skip-existing",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Skip tools that are already present. Defaults to true.",
    )
    install_deps.add_argument(
        "--skip-unsupported",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Skip targets that need another host OS. Defaults to true.",
    )
    install_deps.set_defaults(func=cmd_install_deps)

    deps = sub.add_parser(
        "deps",
        help="Create/check ignored local overrides for first-party package checkouts.",
    )
    add_product_args(deps)
    deps.add_argument(
        "--workspace-root",
        help="Directory containing sibling first-party checkouts. Defaults to the product repo's parent.",
    )
    deps.add_argument(
        "--write",
        action="store_true",
        help="Write pubspec_overrides.yaml and go.work files. Without this, only checks current files.",
    )
    add_json_arg(deps)
    deps.set_defaults(func=cmd_deps)

    build = sub.add_parser("build", help="Build product targets.")
    add_product_args(build)
    build.add_argument("targets", nargs="*", help="Targets or groups. Defaults to desktop.")
    build.add_argument(
        "--execution-mode",
        choices=["local", "github"],
        default="local",
        help="Run locally or dispatch the configured GitHub workflow.",
    )
    add_local_build_args(build)
    add_github_build_args(build)
    build.set_defaults(func=cmd_build)

    artifacts = sub.add_parser("artifacts", help="List expected artifacts for targets.")
    add_product_args(artifacts)
    artifacts.add_argument("targets", nargs="*", help="Targets or groups. Defaults to desktop.")
    artifacts.add_argument("--copy-to", help="Copy existing artifacts into this directory by target.")
    add_json_arg(artifacts)
    artifacts.set_defaults(func=cmd_artifacts)

    deploy = sub.add_parser("deploy", help="Run configured store deployment commands.")
    add_product_args(deploy)
    deploy.add_argument("store", help="Store name from [stores.<name>].")
    deploy.add_argument("--dry-run", action="store_true", help="Print commands without running them.")
    deploy.set_defaults(func=cmd_deploy)

    ci_matrix = sub.add_parser("ci-matrix", help="Generate a GitHub Actions matrix for product targets.")
    add_product_args(ci_matrix)
    ci_matrix.add_argument("targets", nargs="*", help="Targets or groups. Defaults to all.")
    profiles = runner_profile_names()
    ci_matrix.add_argument(
        "--runner-profile",
        choices=profiles or None,
        default=profiles[0] if profiles else "github-hosted",
        help="Runner profile from build.toml.",
    )
    ci_matrix.add_argument("--pretty", action="store_true", help="Print indented JSON.")
    ci_matrix.set_defaults(func=cmd_ci_matrix)

    local_sweep = sub.add_parser("local-sweep", help="Run local builds for products one by one.")
    local_sweep.add_argument("products", nargs="*", help="Products to run. Defaults to all product configs.")
    local_sweep.add_argument(
        "--targets",
        nargs="+",
        default=["desktop"],
        help="Targets or groups for each product. Defaults to desktop.",
    )
    local_sweep.add_argument("--exclude", action="append", help="Product to skip. Repeat as needed.")
    add_local_build_args(local_sweep)
    local_sweep.set_defaults(func=cmd_local_sweep)

    return parser


def main(argv: list[str] | None = None) -> int:
    augment_process_path()
    parser = build_parser()
    args = parser.parse_args(argv)
    set_color_enabled(enabled=not getattr(args, "no_color", False))
    try:
        return int(args.func(args))
    except BuildError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as exc:
        print(f"error: command failed with exit code {exc.returncode}", file=sys.stderr)
        return exc.returncode or 1
