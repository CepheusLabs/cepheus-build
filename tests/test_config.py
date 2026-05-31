"""Tests for cepheus_build.config: host detection, string helpers, stamps, ProductConfig."""

from __future__ import annotations

import platform
import textwrap
from pathlib import Path

import pytest

from cepheus_build.config import (
    HOST_ALIASES,
    HOST_ORDER,
    ProductConfig,
    Stamp,
    compute_stamp,
    current_host,
    host_list,
    load_toml,
    normalize_hosts,
    string_list,
    target_allowed_hosts,
)
from cepheus_build.errors import BuildError

# ---------------------------------------------------------------------------
# HOST_ALIASES
# ---------------------------------------------------------------------------

class TestHostAliases:
    def test_darwin_maps_to_macos(self):
        assert HOST_ALIASES["darwin"] == "macos"

    def test_win32_maps_to_windows(self):
        assert HOST_ALIASES["win32"] == "windows"

    def test_mac_maps_to_macos(self):
        assert HOST_ALIASES["mac"] == "macos"

    def test_canonical_names_are_identity(self):
        for name in ("macos", "windows", "linux"):
            assert HOST_ALIASES[name] == name

    def test_host_order_contains_three(self):
        assert set(HOST_ORDER) == {"linux", "macos", "windows"}


# ---------------------------------------------------------------------------
# current_host()
# ---------------------------------------------------------------------------

class TestCurrentHost:
    def test_returns_normalized_name(self):
        raw = platform.system().lower()
        expected = HOST_ALIASES.get(raw, raw)
        assert current_host() == expected

    def test_result_is_known_host(self):
        host = current_host()
        assert host in HOST_ORDER


# ---------------------------------------------------------------------------
# normalize_hosts()
# ---------------------------------------------------------------------------

class TestNormalizeHosts:
    def test_none_returns_all_hosts(self):
        result = normalize_hosts(None)
        assert result == HOST_ORDER

    def test_empty_list_returns_all_hosts(self):
        result = normalize_hosts([])
        assert result == HOST_ORDER

    def test_single_string(self):
        assert normalize_hosts("macos") == ["macos"]

    def test_darwin_alias_normalized(self):
        assert normalize_hosts("darwin") == ["macos"]

    def test_win32_alias_normalized(self):
        assert normalize_hosts("win32") == ["windows"]

    def test_list_deduplicated(self):
        result = normalize_hosts(["macos", "macos"])
        assert result == ["macos"]

    def test_any_expands_to_all(self):
        result = normalize_hosts("any")
        assert set(result) == {"linux", "macos", "windows"}

    def test_unknown_host_raises(self):
        # A non-empty hosts value with an unrecognized token is treated as a
        # typo and rejected loudly (rather than silently expanding to all hosts).
        with pytest.raises(BuildError):
            normalize_hosts("foobar")

    def test_typo_among_valid_hosts_raises(self):
        # Even when some tokens are valid, a single bad one fails the whole list
        # so the misconfiguration cannot slip through partially applied.
        with pytest.raises(BuildError):
            normalize_hosts(["mcos", "linux"])

    def test_mixed_aliases_and_canonical(self):
        result = normalize_hosts(["darwin", "linux"])
        assert "macos" in result
        assert "linux" in result


# ---------------------------------------------------------------------------
# target_allowed_hosts()
# ---------------------------------------------------------------------------

class TestTargetAllowedHosts:
    def test_empty_target_returns_empty_set(self):
        assert target_allowed_hosts({}) == set()

    def test_hosts_string(self):
        result = target_allowed_hosts({"hosts": "macos"})
        assert result == {"macos"}

    def test_host_singular_key(self):
        result = target_allowed_hosts({"host": "linux"})
        assert result == {"linux"}

    def test_hosts_list(self):
        result = target_allowed_hosts({"hosts": ["macos", "linux"]})
        assert result == {"macos", "linux"}

    def test_alias_normalized(self):
        result = target_allowed_hosts({"hosts": ["darwin", "win32"]})
        assert result == {"macos", "windows"}

    def test_hosts_key_takes_precedence_over_host(self):
        result = target_allowed_hosts({"hosts": "macos", "host": "linux"})
        assert result == {"macos"}


# ---------------------------------------------------------------------------
# string_list()
# ---------------------------------------------------------------------------

class TestStringList:
    def test_none_returns_empty(self):
        assert string_list(None) == []

    def test_string_returns_single_element_list(self):
        assert string_list("hello") == ["hello"]

    def test_list_passthrough(self):
        assert string_list(["a", "b"]) == ["a", "b"]

    def test_list_items_coerced_to_str(self):
        assert string_list([1, 2]) == ["1", "2"]

    def test_empty_list_returns_empty(self):
        assert string_list([]) == []


# ---------------------------------------------------------------------------
# host_list()
# ---------------------------------------------------------------------------

class TestHostList:
    def test_none_returns_empty(self):
        assert host_list(None) == []

    def test_string_returns_list(self):
        assert host_list("tool-a") == ["tool-a"]

    def test_list_passthrough(self):
        assert host_list(["a", "b"]) == ["a", "b"]

    def test_dict_picks_named_host(self):
        d = {"macos": ["a", "b"], "linux": ["c"]}
        result = host_list(d, host="macos")
        assert result == ["a", "b"]

    def test_dict_falls_back_to_default(self):
        d = {"default": ["x"], "linux": ["y"]}
        result = host_list(d, host="windows")
        assert result == ["x"]

    def test_dict_unknown_host_no_default_returns_empty(self):
        d = {"linux": ["c"]}
        result = host_list(d, host="windows")
        assert result == []

    def test_dict_uses_current_host_when_no_host_arg(self, monkeypatch):
        monkeypatch.setattr("cepheus_build.config.current_host", lambda: "linux")
        d = {"linux": ["only-linux"], "macos": ["not-this"]}
        assert host_list(d) == ["only-linux"]


# ---------------------------------------------------------------------------
# Stamp
# ---------------------------------------------------------------------------

class TestStamp:
    def test_full_combines_version_and_build(self):
        s = Stamp("26.5.30", "42")
        assert s.full == "26.5.30+42"

    def test_frozen_dataclass_immutable(self):
        s = Stamp("1.0", "1")
        with pytest.raises((AttributeError, TypeError)):
            s.version = "2.0"  # type: ignore[misc]


# ---------------------------------------------------------------------------
# compute_stamp() — env-driven, no real git
# ---------------------------------------------------------------------------

def _make_config(tmp_path: Path, extra_toml: str = "") -> ProductConfig:
    """Write a minimal product TOML and return a ProductConfig."""
    toml_content = textwrap.dedent(f"""\
        [product]
        slug = "testprod"
        display_name = "Test Product"
        repo_root = "."

        [version]
        env_prefix = "TESTPROD"

        [targets.web]
        hosts = ["linux", "macos", "windows"]
        {extra_toml}
    """)
    cfg_path = tmp_path / "testprod.toml"
    cfg_path.write_text(toml_content)
    return ProductConfig(path=cfg_path, data=load_toml(cfg_path))


class TestComputeStamp:
    def test_cbuild_env_vars_override(self, tmp_path, monkeypatch):
        monkeypatch.setenv("CBUILD_VERSION", "9.9.9")
        monkeypatch.setenv("CBUILD_BUILD_NUMBER", "777")
        # Remove product-prefixed vars so they don't interfere
        monkeypatch.delenv("TESTPROD_BUILD_NAME", raising=False)
        monkeypatch.delenv("TESTPROD_BUILD_NUMBER", raising=False)
        config = _make_config(tmp_path)
        stamp = compute_stamp(config)
        assert stamp.version == "9.9.9"
        assert stamp.build_number == "777"
        assert stamp.full == "9.9.9+777"

    def test_product_prefixed_env_vars_take_precedence_over_cbuild(self, tmp_path, monkeypatch):
        monkeypatch.setenv("CBUILD_VERSION", "1.0.0")
        monkeypatch.setenv("CBUILD_BUILD_NUMBER", "10")
        monkeypatch.setenv("TESTPROD_BUILD_NAME", "5.5.5")
        monkeypatch.setenv("TESTPROD_BUILD_NUMBER", "999")
        config = _make_config(tmp_path)
        stamp = compute_stamp(config)
        assert stamp.version == "5.5.5"
        assert stamp.build_number == "999"

    def test_only_version_env_set_uses_fallback_git(self, tmp_path, monkeypatch):
        # With only version set, build_number comes from git or GITHUB_RUN_NUMBER.
        monkeypatch.setenv("CBUILD_VERSION", "3.1.4")
        monkeypatch.delenv("CBUILD_BUILD_NUMBER", raising=False)
        monkeypatch.delenv("TESTPROD_BUILD_NAME", raising=False)
        monkeypatch.delenv("TESTPROD_BUILD_NUMBER", raising=False)
        monkeypatch.setenv("GITHUB_RUN_NUMBER", "55")
        config = _make_config(tmp_path)
        stamp = compute_stamp(config)
        # repo_root is tmp_path which is not a git repo; falls back to GITHUB_RUN_NUMBER
        assert stamp.version == "3.1.4"
        assert stamp.build_number == "55"

    def test_all_env_missing_uses_github_run_number(self, tmp_path, monkeypatch):
        for key in ["CBUILD_VERSION", "CBUILD_BUILD_NUMBER", "TESTPROD_BUILD_NAME", "TESTPROD_BUILD_NUMBER"]:
            monkeypatch.delenv(key, raising=False)
        monkeypatch.setenv("GITHUB_RUN_NUMBER", "42")
        config = _make_config(tmp_path)
        stamp = compute_stamp(config)
        # tmp_path is not a git repo so git falls back to GITHUB_RUN_NUMBER
        assert stamp.build_number == "42"


# ---------------------------------------------------------------------------
# ProductConfig.expand_targets()
# ---------------------------------------------------------------------------

def _make_multi_target_config(tmp_path: Path) -> ProductConfig:
    toml_content = textwrap.dedent("""\
        [product]
        slug = "myprod"
        display_name = "My Product"
        repo_root = "."

        [groups]
        desktop = ["macos", "linux"]
        all = ["macos", "linux", "web"]

        [targets.macos]
        hosts = ["macos"]

        [targets.linux]
        hosts = ["linux"]

        [targets.web]
        hosts = ["linux", "macos", "windows"]

        [targets.disabled_target]
        hosts = ["linux"]
        enabled = false
    """)
    cfg_path = tmp_path / "myprod.toml"
    cfg_path.write_text(toml_content)
    return ProductConfig(path=cfg_path, data=load_toml(cfg_path))


class TestExpandTargets:
    def test_group_expands_to_members(self, tmp_path):
        config = _make_multi_target_config(tmp_path)
        result = config.expand_targets(["desktop"])
        assert result == ["macos", "linux"]

    def test_explicit_targets_returned_as_is(self, tmp_path):
        config = _make_multi_target_config(tmp_path)
        result = config.expand_targets(["web", "linux"])
        assert result == ["web", "linux"]

    def test_disabled_target_excluded(self, tmp_path):
        config = _make_multi_target_config(tmp_path)
        result = config.expand_targets(["all"])
        assert "disabled_target" not in result

    def test_deduplication(self, tmp_path):
        config = _make_multi_target_config(tmp_path)
        result = config.expand_targets(["macos", "macos"])
        assert result.count("macos") == 1

    def test_default_group_is_desktop_when_empty(self, tmp_path):
        config = _make_multi_target_config(tmp_path)
        result = config.expand_targets([])
        assert result == ["macos", "linux"]

    def test_unknown_target_raises(self, tmp_path):
        config = _make_multi_target_config(tmp_path)
        with pytest.raises(BuildError):
            config.expand_targets(["nonexistent_only"])

    def test_all_group(self, tmp_path):
        config = _make_multi_target_config(tmp_path)
        result = config.expand_targets(["all"])
        assert set(result) == {"macos", "linux", "web"}
