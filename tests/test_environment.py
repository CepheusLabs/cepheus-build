"""Tests for cepheus_build.environment: resolve_value, expand_env_refs, target_env_values."""

from __future__ import annotations

from cepheus_build.environment import (
    _git_token_env,
    expand_env_refs,
    resolve_value,
    target_env_values,
)

# ---------------------------------------------------------------------------
# _git_token_env()
# ---------------------------------------------------------------------------

class TestGitTokenEnv:
    def test_no_token_no_entries(self):
        assert _git_token_env({}) == {}

    def test_token_synthesizes_git_config_env(self):
        extra = _git_token_env({"CEPHEUS_READ_TOKEN": "ghp_abc"})
        assert extra["GIT_CONFIG_COUNT"] == "1"
        assert extra["GIT_CONFIG_KEY_0"] == (
            "url.https://x-access-token:ghp_abc@github.com/.insteadOf"
        )
        assert extra["GIT_CONFIG_VALUE_0"] == "https://github.com/"
        assert extra["GOPRIVATE"] == "github.com/CepheusLabs"

    def test_respects_existing_git_config_entries(self):
        extra = _git_token_env({"CEPHEUS_READ_TOKEN": "t", "GIT_CONFIG_COUNT": "2"})
        assert extra["GIT_CONFIG_COUNT"] == "3"
        assert "GIT_CONFIG_KEY_2" in extra

    def test_does_not_clobber_goprivate(self):
        extra = _git_token_env({"CEPHEUS_READ_TOKEN": "t", "GOPRIVATE": "example.com/x"})
        assert "GOPRIVATE" not in extra


# ---------------------------------------------------------------------------
# resolve_value()
# ---------------------------------------------------------------------------

class TestResolveValue:
    def test_plain_string_returned_as_is(self):
        assert resolve_value("hello", {}) == "hello"

    def test_env_colon_form_present(self):
        assert resolve_value("env:MY_VAR", {"MY_VAR": "found"}) == "found"

    def test_env_colon_form_missing_returns_empty(self):
        assert resolve_value("env:MISSING_VAR", {}) == ""

    def test_env_colon_form_with_default_present(self):
        env = {"FOO": "actual"}
        assert resolve_value("env:FOO=fallback", env) == "actual"

    def test_env_colon_form_with_default_missing(self):
        assert resolve_value("env:BAR=fallback_val", {}) == "fallback_val"

    def test_dict_form_env_present(self):
        spec = {"env": "MYKEY", "default": "def"}
        assert resolve_value(spec, {"MYKEY": "val"}) == "val"

    def test_dict_form_env_missing_uses_default(self):
        spec = {"env": "MYKEY", "default": "thedefault"}
        assert resolve_value(spec, {}) == "thedefault"

    def test_dict_form_no_env_key_uses_default(self):
        spec = {"default": "only_default"}
        assert resolve_value(spec, {}) == "only_default"

    def test_dollar_var_expansion_via_os_environ(self, monkeypatch):
        monkeypatch.setenv("CB_TEST_VAR", "expanded_value")
        result = resolve_value("$CB_TEST_VAR", {})
        assert result == "expanded_value"


# ---------------------------------------------------------------------------
# expand_env_refs()
# ---------------------------------------------------------------------------

class TestExpandEnvRefs:
    def test_dollar_name_replaced(self):
        assert expand_env_refs("$FOO", {"FOO": "bar"}) == "bar"

    def test_dollar_brace_name_replaced(self):
        assert expand_env_refs("${FOO}", {"FOO": "baz"}) == "baz"

    def test_unknown_ref_left_intact(self):
        result = expand_env_refs("$UNKNOWN", {"KNOWN": "x"})
        assert result == "$UNKNOWN"

    def test_mixed_known_and_unknown(self):
        result = expand_env_refs("$KNOWN and $UNKNOWN", {"KNOWN": "a"})
        assert result == "a and $UNKNOWN"

    def test_no_refs_unchanged(self):
        assert expand_env_refs("no refs here", {}) == "no refs here"

    def test_multiple_refs(self):
        result = expand_env_refs("$A/$B", {"A": "x", "B": "y"})
        assert result == "x/y"

    def test_brace_and_plain_mixed(self):
        result = expand_env_refs("${A}-$B", {"A": "one", "B": "two"})
        assert result == "one-two"


# ---------------------------------------------------------------------------
# target_env_values()
# ---------------------------------------------------------------------------

class TestTargetEnvValues:
    def test_no_env_key_returns_empty(self):
        target: dict = {"commands": ["echo hi"]}
        assert target_env_values(target, {}) == {}

    def test_flat_env_dict_resolved(self):
        target = {"env": {"MY_KEY": "env:MY_SRC=default_val"}}
        result = target_env_values(target, {"MY_SRC": "source_value"})
        assert result == {"MY_KEY": "source_value"}

    def test_flat_env_dict_default_used(self):
        target = {"env": {"MY_KEY": "env:MY_SRC=default_val"}}
        result = target_env_values(target, {})
        assert result == {"MY_KEY": "default_val"}

    def test_host_keyed_env_merges_default_and_host(self, monkeypatch):
        monkeypatch.setattr("cepheus_build.environment.current_host", lambda: "macos")
        target = {
            "env": {
                "default": {"SHARED": "base", "PLATFORM": "generic"},
                "macos": {"PLATFORM": "apple"},
            }
        }
        result = target_env_values(target, {})
        assert result["SHARED"] == "base"
        assert result["PLATFORM"] == "apple"

    def test_host_keyed_env_uses_default_when_no_host_entry(self, monkeypatch):
        monkeypatch.setattr("cepheus_build.environment.current_host", lambda: "windows")
        target = {
            "env": {
                "default": {"KEY": "default_val"},
                "macos": {"KEY": "mac_val"},
            }
        }
        result = target_env_values(target, {})
        assert result["KEY"] == "default_val"

    def test_env_ref_expansion_in_values(self):
        target = {"env": {"OUT": "$BASE/sub"}}
        result = target_env_values(target, {"BASE": "/home/user"})
        assert result["OUT"] == "/home/user/sub"
