"""Tests for product-config schema validation.

These exercise the built-in fallback validator directly (always available) and,
when jsonschema is installed, assert the real engine agrees on valid/invalid.
The CLI smoke layer separately confirms the real products all validate.
"""

from __future__ import annotations

import pytest

from cepheus_build.validation import _fallback_validate, load_schema, validate_product_data

VALID_PRODUCT = {
    "product": {
        "slug": "demo",
        "display_name": "Demo",
        "repo_root": "../../demo",
        "app_dir": "app",
    },
    "targets": {
        "web": {
            "hosts": ["linux", "macos", "windows"],
            "commands": ["make web"],
            "tools": ["flutter"],
        },
    },
}


def _fallback(data):
    return _fallback_validate(data, load_schema())


class TestFallbackValidatorValid:
    def test_minimal_valid_product_has_no_errors(self):
        assert _fallback(VALID_PRODUCT) == []

    def test_host_keyed_commands_accepted(self):
        data = {
            "product": {"slug": "d", "display_name": "D", "app_dir": "."},
            "targets": {
                "os": {
                    "commands": {"linux": ["a"], "macos": ["b"], "windows": ["c"]},
                    "tools": {"linux": ["docker"]},
                },
            },
        }
        assert _fallback(data) == []


class TestFallbackValidatorErrors:
    def test_missing_required_product_keys(self):
        data = {"product": {"slug": "d"}, "targets": {}}
        errors = _fallback(data)
        assert any("display_name" in e for e in errors)
        assert any("app_dir" in e for e in errors)

    def test_missing_top_level_required(self):
        # 'product' and 'targets' are both required at the root.
        errors = _fallback({})
        assert any("product" in e for e in errors)
        assert any("targets" in e for e in errors)

    def test_hosts_must_be_array(self):
        data = {
            "product": {"slug": "d", "display_name": "D", "app_dir": "."},
            "targets": {"web": {"hosts": "macos"}},
        }
        errors = _fallback(data)
        assert any("hosts" in e and "array" in e for e in errors)

    def test_commands_string_in_host_map_rejected(self):
        data = {
            "product": {"slug": "d", "display_name": "D", "app_dir": "."},
            "targets": {"web": {"commands": {"linux": "make web"}}},
        }
        errors = _fallback(data)
        assert any("commands" in e for e in errors)

    def test_enabled_must_be_boolean(self):
        data = {
            "product": {"slug": "d", "display_name": "D", "app_dir": "."},
            "targets": {"web": {"enabled": "yes"}},
        }
        errors = _fallback(data)
        assert any("enabled" in e for e in errors)

    def test_store_required_env_must_be_string_list(self):
        data = {
            "product": {"slug": "d", "display_name": "D", "app_dir": "."},
            "targets": {"web": {}},
            "stores": {"play": {"required_env": "TOKEN"}},
        }
        errors = _fallback(data)
        assert any("required_env" in e for e in errors)


class TestPublicEntrypoint:
    def test_validate_product_data_valid(self):
        assert validate_product_data(VALID_PRODUCT) == []

    def test_validate_product_data_invalid(self):
        assert validate_product_data({"product": {"slug": "x"}, "targets": {}})


class TestJsonschemaAgreement:
    """When jsonschema is installed, it must agree with our valid fixture and
    flag the obviously-invalid one. (importorskip when not installed.)"""

    def test_engine_accepts_valid(self):
        jsonschema = pytest.importorskip("jsonschema")
        schema = load_schema()
        validator = jsonschema.validators.validator_for(schema)(schema)
        assert list(validator.iter_errors(VALID_PRODUCT)) == []

    def test_engine_rejects_invalid(self):
        pytest.importorskip("jsonschema")
        errors = validate_product_data({"product": {"slug": "x"}, "targets": {}})
        assert errors
