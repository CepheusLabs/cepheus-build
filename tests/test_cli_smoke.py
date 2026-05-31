"""CLI smoke tests via subprocess: describe and list subcommands."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CLI = str(REPO_ROOT / "bin" / "cepheus-build")


def run_cli(*args: str, timeout: int = 30) -> subprocess.CompletedProcess:
    """Run the CLI with the current Python interpreter."""
    return subprocess.run(
        [sys.executable, CLI, *args],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=timeout,
    )


class TestListCommand:
    def test_list_json_exits_zero(self):
        result = run_cli("list", "--json")
        assert result.returncode == 0, result.stderr

    def test_list_json_parses(self):
        result = run_cli("list", "--json")
        data = json.loads(result.stdout)
        assert isinstance(data, list)

    def test_list_json_has_slug_and_display_name(self):
        result = run_cli("list", "--json")
        data = json.loads(result.stdout)
        assert len(data) > 0
        for item in data:
            assert "slug" in item
            assert "display_name" in item

    def test_list_json_includes_printdeck(self):
        result = run_cli("list", "--json")
        data = json.loads(result.stdout)
        slugs = {item["slug"] for item in data}
        assert "printdeck" in slugs


class TestDescribeCommand:
    def test_describe_no_product_exits_zero(self):
        result = run_cli("describe", "--json")
        assert result.returncode == 0, result.stderr

    def test_describe_no_product_has_products_and_profiles(self):
        result = run_cli("describe", "--json")
        data = json.loads(result.stdout)
        assert "products" in data
        assert "runner_profiles" in data

    def test_describe_products_list_has_slug(self):
        result = run_cli("describe", "--json")
        data = json.loads(result.stdout)
        assert isinstance(data["products"], list)
        for prod in data["products"]:
            assert "slug" in prod

    def test_describe_with_product_exits_zero(self):
        result = run_cli("describe", "-p", "printdeck", "--json")
        assert result.returncode == 0, result.stderr

    def test_describe_printdeck_has_expected_keys(self):
        result = run_cli("describe", "-p", "printdeck", "--json")
        data = json.loads(result.stdout)
        for key in ("slug", "display_name", "targets", "groups", "stores", "runner_profiles"):
            assert key in data, f"Missing key: {key}"

    def test_describe_printdeck_slug(self):
        result = run_cli("describe", "-p", "printdeck", "--json")
        data = json.loads(result.stdout)
        assert data["slug"] == "printdeck"

    def test_describe_printdeck_has_targets(self):
        result = run_cli("describe", "-p", "printdeck", "--json")
        data = json.loads(result.stdout)
        assert isinstance(data["targets"], dict)
        assert len(data["targets"]) > 0

    def test_describe_runner_profiles_have_value_and_label(self):
        result = run_cli("describe", "--json")
        data = json.loads(result.stdout)
        for profile in data["runner_profiles"]:
            assert "value" in profile
            assert "label" in profile

    def test_describe_unknown_product_exits_nonzero(self):
        result = run_cli("describe", "-p", "this-does-not-exist", "--json")
        assert result.returncode != 0


class TestValidateCommand:
    def test_all_real_products_validate(self):
        result = run_cli("validate")
        assert result.returncode == 0, result.stdout + result.stderr

    def test_validate_json_shape(self):
        result = run_cli("validate", "--json")
        data = json.loads(result.stdout)
        assert data["ok"] is True
        assert isinstance(data["results"], list)
        assert all(r["valid"] for r in data["results"])

    def test_validate_single_product(self):
        result = run_cli("validate", "-p", "printdeck")
        assert result.returncode == 0


class TestStampJson:
    def test_stamp_json_has_all_keys(self):
        result = run_cli("stamp", "-p", "printdeck", "--json")
        data = json.loads(result.stdout)
        for key in ("version", "build_number", "full_version", "tag"):
            assert key in data

    def test_stamp_default_is_plain_full_version(self):
        result = run_cli("stamp", "-p", "printdeck")
        # plain mode: a single "version+build" line, not JSON
        assert "+" in result.stdout
        assert not result.stdout.strip().startswith("{")


class TestArtifactsJson:
    def test_artifacts_json_shape(self):
        result = run_cli("artifacts", "-p", "printdeck", "web", "--json")
        data = json.loads(result.stdout)
        assert "targets" in data
        assert "web" in data["targets"]
        for row in data["targets"]["web"]:
            assert "path" in row
            assert "exists" in row
