"""Validate product TOML configs against schemas/product.schema.json.

The full `jsonschema` library is an optional dependency. When it is installed
we use it for complete validation; otherwise we fall back to a small built-in
checker that enforces the structural rules this repo's schema actually relies
on (required keys, object/array/string/boolean types, and the
``stringListOrHostMap`` shape for commands/pre/post/tools). The fallback is
intentionally conservative: it reports clear errors for the common mistakes
(typos, wrong types, missing required keys) without trying to be a general
JSON Schema engine.
"""

from __future__ import annotations

import json
from typing import Any

from .config import PRODUCT_SCHEMA_PATH
from .errors import BuildError

_HOST_MAP_KEYS = {"linux", "macos", "windows", "default"}


def load_schema() -> dict[str, Any]:
    try:
        with PRODUCT_SCHEMA_PATH.open("rb") as handle:
            return json.load(handle)
    except FileNotFoundError as exc:  # pragma: no cover - shipped with repo
        raise BuildError(f"Product schema not found: {PRODUCT_SCHEMA_PATH}") from exc
    except json.JSONDecodeError as exc:  # pragma: no cover - shipped with repo
        raise BuildError(f"Invalid product schema JSON: {exc}") from exc


def validate_product_data(data: dict[str, Any]) -> list[str]:
    """Return a list of human-readable validation errors (empty == valid)."""
    schema = load_schema()
    try:
        import jsonschema  # type: ignore
    except ImportError:
        return _fallback_validate(data, schema)

    validator_cls = jsonschema.validators.validator_for(schema)
    validator_cls.check_schema(schema)
    validator = validator_cls(schema)
    errors = []
    for err in sorted(validator.iter_errors(data), key=lambda e: list(e.path)):
        location = "/".join(str(p) for p in err.path) or "<root>"
        errors.append(f"{location}: {err.message}")
    return errors


# ---------------------------------------------------------------------------
# Built-in fallback (used when jsonschema is not installed)
# ---------------------------------------------------------------------------

def _fallback_validate(data: dict[str, Any], schema: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    _check_object(data, schema, "<root>", errors)
    return errors


def _check_object(
    value: Any,
    schema: dict[str, Any],
    path: str,
    errors: list[str],
) -> None:
    if not isinstance(value, dict):
        errors.append(f"{path}: expected an object/table")
        return
    for required in schema.get("required", []):
        if required not in value:
            errors.append(f"{path}: missing required key '{required}'")
    props: dict[str, Any] = schema.get("properties", {})
    additional = schema.get("additionalProperties", True)
    for key, sub_value in value.items():
        if key in props:
            _check_value(sub_value, props[key], f"{path}/{key}", errors)
        elif additional is False:
            errors.append(f"{path}: unexpected key '{key}'")
        elif isinstance(additional, dict):
            _check_value(sub_value, additional, f"{path}/{key}", errors)


def _check_value(
    value: Any,
    schema: dict[str, Any],
    path: str,
    errors: list[str],
) -> None:
    # Resolve the handful of $ref/oneOf forms our schema actually uses.
    if "$ref" in schema:
        ref = schema["$ref"]
        if ref.endswith("stringListOrHostMap"):
            _check_string_list_or_host_map(value, path, errors)
            return
        if ref.endswith("stringList"):
            _check_string_list(value, path, errors)
            return
        return  # unknown ref: skip rather than false-positive
    if "oneOf" in schema:
        # stringListOrHostMap is expressed as a top-level oneOf too.
        _check_string_list_or_host_map(value, path, errors)
        return

    expected = schema.get("type")
    if expected == "object":
        _check_object(value, schema, path, errors)
    elif expected == "array":
        if not isinstance(value, list):
            errors.append(f"{path}: expected an array")
            return
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for i, item in enumerate(value):
                _check_value(item, item_schema, f"{path}[{i}]", errors)
    elif expected == "string":
        if not isinstance(value, str):
            errors.append(f"{path}: expected a string")
    elif expected == "boolean":
        if not isinstance(value, bool):
            errors.append(f"{path}: expected true/false")


def _check_string_list(value: Any, path: str, errors: list[str]) -> None:
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        errors.append(f"{path}: expected a list of strings")


def _check_string_list_or_host_map(value: Any, path: str, errors: list[str]) -> None:
    if isinstance(value, list):
        _check_string_list(value, path, errors)
        return
    if isinstance(value, dict):
        for key, sub in value.items():
            if not isinstance(sub, list) or not all(isinstance(v, str) for v in sub):
                errors.append(f"{path}/{key}: expected a list of strings")
        return
    errors.append(f"{path}: expected a list of strings or a host-keyed table")
