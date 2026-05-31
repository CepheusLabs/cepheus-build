"""Tests for cepheus_build.process: failure detection, CocoaPods repair, color helpers."""

from __future__ import annotations

import pytest

from cepheus_build.process import (
    COCOAPODS_SPECS_REPAIR_PATTERNS,
    COMMAND_OUTPUT_FAILURE_PATTERNS,
    display_command,
    set_color_enabled,
    shell_quote,
    should_repair_cocoapods_specs,
    should_treat_output_as_failure,
    style_prefix,
    use_color,
)


# ---------------------------------------------------------------------------
# should_treat_output_as_failure()
# ---------------------------------------------------------------------------

class TestShouldTreatOutputAsFailure:
    def test_empty_output_is_not_failure(self):
        assert should_treat_output_as_failure("") is False

    def test_none_like_empty_string(self):
        assert should_treat_output_as_failure("") is False

    def test_matching_pattern_ipa_error(self):
        output = "Encountered error while creating the IPA: something went wrong"
        assert should_treat_output_as_failure(output) is True

    def test_matching_pattern_export_archive(self):
        output = "exportArchive Failed"
        assert should_treat_output_as_failure(output) is True

    def test_all_patterns_match(self):
        for pattern in COMMAND_OUTPUT_FAILURE_PATTERNS:
            assert should_treat_output_as_failure(f"prefix {pattern} suffix") is True

    def test_unrelated_output_not_failure(self):
        assert should_treat_output_as_failure("Build succeeded.") is False

    def test_partial_match_not_failure(self):
        # "exportArchive" alone without "Failed" shouldn't trigger (pattern requires exact phrase)
        assert should_treat_output_as_failure("exportArchive succeeded") is False


# ---------------------------------------------------------------------------
# should_repair_cocoapods_specs()
# ---------------------------------------------------------------------------

class TestShouldRepairCocoapodsSpecs:
    def test_empty_output_false(self):
        assert should_repair_cocoapods_specs("") is False

    def test_out_of_date_message_triggers(self):
        output = "CocoaPods's specs repository is too out-of-date to satisfy dependencies"
        assert should_repair_cocoapods_specs(output) is True

    def test_incompatible_versions_triggers(self):
        output = "CocoaPods could not find compatible versions for pod 'Firebase'"
        assert should_repair_cocoapods_specs(output) is True

    def test_all_explicit_patterns_match(self):
        for pattern in COCOAPODS_SPECS_REPAIR_PATTERNS:
            assert should_repair_cocoapods_specs(pattern) is True

    def test_cocoapods_plus_pod_repo_update_triggers(self):
        output = "Error: CocoaPods integration issue. Try: pod repo update"
        assert should_repair_cocoapods_specs(output) is True

    def test_generic_build_error_no_trigger(self):
        assert should_repair_cocoapods_specs("Build failed: Swift compilation error") is False

    def test_pod_alone_no_trigger(self):
        assert should_repair_cocoapods_specs("pod install completed") is False


# ---------------------------------------------------------------------------
# shell_quote() and display_command()
# ---------------------------------------------------------------------------

class TestShellQuote:
    def test_simple_word_unchanged_on_unix(self):
        import os
        if os.name != "nt":
            assert shell_quote("flutter") == "flutter"

    def test_space_in_value_quoted_on_unix(self):
        import os
        if os.name != "nt":
            result = shell_quote("hello world")
            assert " " not in result or result.startswith("'")

    def test_display_command_joins_with_spaces(self):
        result = display_command("flutter", ["build", "macos"])
        assert "flutter" in result
        assert "build" in result
        assert "macos" in result


# ---------------------------------------------------------------------------
# Color helpers: use_color(), style_prefix(), set_color_enabled()
# ---------------------------------------------------------------------------

class TestColorHelpers:
    def test_no_color_env_disables_color(self, monkeypatch):
        import cepheus_build.process as proc
        monkeypatch.setenv("NO_COLOR", "1")
        # Reset force-off so only env governs
        old = proc._COLOR_FORCE_OFF
        proc._COLOR_FORCE_OFF = False
        try:
            assert use_color() is False
        finally:
            proc._COLOR_FORCE_OFF = old

    def test_set_color_enabled_false_disables(self, monkeypatch):
        import cepheus_build.process as proc
        monkeypatch.delenv("NO_COLOR", raising=False)
        old = proc._COLOR_FORCE_OFF
        proc._COLOR_FORCE_OFF = False
        set_color_enabled(False)
        try:
            assert use_color() is False
        finally:
            proc._COLOR_FORCE_OFF = old

    def test_set_color_enabled_no_color_flag(self, monkeypatch):
        import cepheus_build.process as proc
        monkeypatch.delenv("NO_COLOR", raising=False)
        old = proc._COLOR_FORCE_OFF
        proc._COLOR_FORCE_OFF = False
        set_color_enabled(no_color=True)
        try:
            assert use_color() is False
        finally:
            proc._COLOR_FORCE_OFF = old

    def test_style_prefix_no_ansi_when_color_off(self, monkeypatch):
        import cepheus_build.process as proc
        monkeypatch.setenv("NO_COLOR", "1")
        old = proc._COLOR_FORCE_OFF
        proc._COLOR_FORCE_OFF = True
        try:
            result = style_prefix("+")
            assert "\033[" not in result
            assert result == "+"
        finally:
            proc._COLOR_FORCE_OFF = old

    def test_use_color_with_non_tty_stream_is_false(self):
        import io
        stream = io.StringIO()
        # StringIO has no isatty or returns False
        assert use_color(stream) is False
