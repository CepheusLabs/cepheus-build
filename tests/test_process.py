"""Tests for cepheus_build.process: failure detection, CocoaPods repair, color helpers."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

from cepheus_build.process import (
    COCOAPODS_SPECS_REPAIR_PATTERNS,
    COMMAND_OUTPUT_FAILURE_PATTERNS,
    display_command,
    run_argv,
    set_color_enabled,
    shell_quote,
    should_repair_cocoapods_specs,
    should_treat_output_as_failure,
    style_prefix,
    use_color,
)

# ---------------------------------------------------------------------------
# run_argv()
# ---------------------------------------------------------------------------

class TestRunArgv:
    """Real subprocesses via the Python interpreter: portable on every host OS."""

    def _env(self):
        return dict(os.environ)

    def test_success_streams_output(self, capfd):
        run_argv(
            [sys.executable, "-c", "print('argv-exec ok')"],
            Path.cwd(),
            self._env(),
        )
        out, _err = capfd.readouterr()
        assert "argv-exec ok" in out

    def test_argument_with_spaces_survives_verbatim(self, capfd):
        # The whole point of argv-exec: one argv element arrives as ONE
        # sys.argv entry, with no local shell re-parsing it (the failure mode
        # of shell-string dispatch on native Windows, where shell_quote is a
        # no-op).
        marker = "cd '/x y'; $env:A = 'b c'"
        run_argv(
            [sys.executable, "-c", "import sys; print(sys.argv[1])", marker],
            Path.cwd(),
            self._env(),
        )
        out, _err = capfd.readouterr()
        assert marker in out

    def test_nonzero_exit_raises(self):
        with pytest.raises(subprocess.CalledProcessError):
            run_argv(
                [sys.executable, "-c", "raise SystemExit(3)"],
                Path.cwd(),
                self._env(),
            )

    def test_dry_run_echoes_without_executing(self, capfd, tmp_path):
        witness = tmp_path / "ran"
        run_argv(
            [sys.executable, "-c", f"open({str(witness)!r}, 'w').close()"],
            Path.cwd(),
            self._env(),
            dry_run=True,
        )
        out, _err = capfd.readouterr()
        assert "+ " in out
        assert not witness.exists()

    def test_prefix_applied_to_echo_and_stream(self, capfd):
        run_argv(
            [sys.executable, "-c", "print('payload')"],
            Path.cwd(),
            self._env(),
            prefix="[macos] ",
        )
        out, _err = capfd.readouterr()
        lines = out.splitlines()
        assert any(line.startswith("[macos] +") for line in lines)
        assert "[macos] payload" in lines

    def test_redact_masks_echo_but_child_gets_value(self, capfd):
        run_argv(
            [sys.executable, "-c", "import sys; print('got:' + sys.argv[1])", "hunter2"],
            Path.cwd(),
            self._env(),
            redact=["hunter2"],
        )
        out, _err = capfd.readouterr()
        echo = next(line for line in out.splitlines() if line.startswith("+"))
        assert "hunter2" not in echo
        assert "***" in echo
        assert "got:hunter2" in out  # delivered verbatim to the child

    def test_missing_binary_is_build_error(self):
        from cepheus_build.errors import BuildError

        with pytest.raises(BuildError, match="not found on PATH"):
            run_argv(
                ["definitely-not-a-real-binary-xyz"],
                Path.cwd(),
                self._env(),
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

    def test_matching_pattern_flutter_build_process_failed(self):
        # Flutter desktop builds (notably Windows) can print this while still
        # exiting 0, so the failure must be caught from the output.
        output = "Building Windows application...  12.3s\nBuild process failed."
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
