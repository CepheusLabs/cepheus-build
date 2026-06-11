"""Tests for cepheus_build.container: profile lookup, routing, argv builders.

The argv/command builders are pure functions, so they are asserted directly
(OS-independent). ``cmd_container_build`` is exercised with ``run_argv``
monkeypatched to record the dispatched argv lists (no shell involved),
mirroring tests/test_builder.py.
"""

from __future__ import annotations

import textwrap
from types import SimpleNamespace

import pytest

from cepheus_build import container
from cepheus_build.config import ProductConfig, Stamp, load_toml
from cepheus_build.errors import BuildError

STAMP = Stamp("26.6.11", "1188")


def _config(tmp_path, body: str) -> ProductConfig:
    content = textwrap.dedent(
        """\
        [product]
        slug = "demo"
        display_name = "Demo"
        repo_root = "."
        app_dir = "."

        """
    ) + textwrap.dedent(body)
    path = tmp_path / "demo.toml"
    path.write_text(content)
    return ProductConfig(path=path, data=load_toml(path))


def _three_host_config(tmp_path) -> ProductConfig:
    return _config(
        tmp_path,
        """\
        [targets.linux]
        hosts = ["linux"]
        commands = ["make linux"]
        artifacts = ["build/linux"]

        [targets.macos]
        hosts = ["macos"]
        commands = ["make macos"]
        artifacts = ["build/macos/Build/Products/Release/demo.app", "dist/macos/Demo-*.dmg"]

        [targets.windows]
        hosts = ["windows"]
        commands = ["make windows"]
        artifacts = ["packaging/windows/dist/*.exe"]
        """,
    )


def _args(**overrides) -> SimpleNamespace:
    base = dict(
        mode="release",
        keep_going=True,
        check_tools=True,
        flutter_arg=[],
        dry_run=False,
        container_profile="default",
        container_host="",
        parallel_hosts=True,
        targets=None,
    )
    base.update(overrides)
    return SimpleNamespace(**base)


@pytest.fixture(autouse=True)
def _transport_tools_ok(monkeypatch):
    """cmd_container_build fail-fasts on missing docker/ssh/rsync; not under test."""
    monkeypatch.setattr(container, "tool_status", lambda tool: (True, "ok"))


# ---------------------------------------------------------------------------
# Profile lookup
# ---------------------------------------------------------------------------


class TestProfileLookup:
    def test_default_profile_present(self):
        assert "default" in container.container_profile_names()

    def test_profile_names_sorted(self):
        names = container.container_profile_names()
        assert names == sorted(names)

    def test_default_profile_config_has_hosts(self):
        cfg = container.container_profile_config("default")
        assert cfg["linux"]["kind"] == "docker"
        assert cfg["windows"]["kind"] == "ssh"
        assert cfg["macos"]["kind"] == "ssh"

    def test_unknown_profile_raises(self):
        with pytest.raises(BuildError):
            container.container_profile_config("nope")

    def test_host_endpoint_missing_raises(self):
        with pytest.raises(BuildError):
            container.host_endpoint({"label": "x"}, "linux")


# ---------------------------------------------------------------------------
# Target routing
# ---------------------------------------------------------------------------


class TestGroupTargetsByHost:
    def test_routes_each_target_to_its_host(self, tmp_path):
        config = _three_host_config(tmp_path)
        grouped = container.group_targets_by_host(config, ["linux", "macos", "windows"])
        assert grouped == {"linux": ["linux"], "macos": ["macos"], "windows": ["windows"]}

    def test_multi_host_target_prefers_linux(self, tmp_path):
        config = _config(
            tmp_path,
            """\
            [targets.web]
            hosts = ["linux", "macos", "windows"]
            commands = ["make web"]
            """,
        )
        grouped = container.group_targets_by_host(config, ["web"])
        assert grouped == {"linux": ["web"]}

    def test_preserves_host_order(self, tmp_path):
        config = _three_host_config(tmp_path)
        grouped = container.group_targets_by_host(config, ["windows", "macos", "linux"])
        assert list(grouped.keys()) == ["linux", "macos", "windows"]


# ---------------------------------------------------------------------------
# Env passthrough + stamp injection
# ---------------------------------------------------------------------------


class TestContainerEnvPairs:
    def test_always_carries_stamp(self, tmp_path):
        config = _three_host_config(tmp_path)
        pairs = dict(container.container_env_pairs(config, STAMP))
        assert pairs["CBUILD_VERSION"] == "26.6.11"
        assert pairs["CBUILD_BUILD_NUMBER"] == "1188"

    def test_forwards_set_dart_define_env(self, tmp_path, monkeypatch):
        config = _config(
            tmp_path,
            """\
            [flutter.dart_defines]
            API_BASE_URL = { env = "DEMO_API", default = "https://x" }

            [targets.linux]
            hosts = ["linux"]
            commands = ["make linux"]
            """,
        )
        monkeypatch.setenv("DEMO_API", "https://staging.example")
        pairs = dict(container.container_env_pairs(config, STAMP))
        assert pairs["DEMO_API"] == "https://staging.example"

    def test_skips_unset_dart_define_env(self, tmp_path, monkeypatch):
        config = _config(
            tmp_path,
            """\
            [flutter.dart_defines]
            API_BASE_URL = { env = "DEMO_UNSET", default = "https://x" }

            [targets.linux]
            hosts = ["linux"]
            commands = ["make linux"]
            """,
        )
        monkeypatch.delenv("DEMO_UNSET", raising=False)
        pairs = dict(container.container_env_pairs(config, STAMP))
        assert "DEMO_UNSET" not in pairs

    def test_read_token_forwarded_when_set(self, tmp_path, monkeypatch):
        config = _three_host_config(tmp_path)
        monkeypatch.setenv("CEPHEUS_READ_TOKEN", "ghp_secret")
        pairs = dict(container.container_env_pairs(config, STAMP))
        assert pairs["CEPHEUS_READ_TOKEN"] == "ghp_secret"

    def test_read_token_name_only_in_docker_argv(self, tmp_path, monkeypatch):
        config = _three_host_config(tmp_path)
        monkeypatch.setenv("CEPHEUS_READ_TOKEN", "ghp_secret")
        argv = container.docker_argv(
            config, ["linux"], {"kind": "docker", "image": "img"}, STAMP, _args()
        )
        assert "CEPHEUS_READ_TOKEN" in argv
        assert not any("ghp_secret" in part for part in argv)


# ---------------------------------------------------------------------------
# build subcommand args
# ---------------------------------------------------------------------------


class TestBuildSubcommandArgs:
    def test_core_flags(self, tmp_path):
        config = _three_host_config(tmp_path)
        argv = container.build_subcommand_args(
            config, ["linux"], _args(), repo_root="/work"
        )
        assert argv[:3] == ["build", "-p", "demo"]
        # The inner build must never recurse or re-pull.
        assert "--execution-mode" in argv
        assert argv[argv.index("--execution-mode") + 1] == "local"
        assert "--no-sync" in argv
        assert argv[argv.index("--repo-root") + 1] == "/work"

    def test_keep_going_toggle(self, tmp_path):
        config = _three_host_config(tmp_path)
        assert "--keep-going" in container.build_subcommand_args(
            config, ["linux"], _args(keep_going=True), repo_root="."
        )
        assert "--no-keep-going" in container.build_subcommand_args(
            config, ["linux"], _args(keep_going=False), repo_root="."
        )

    def test_no_check_tools_passed_through(self, tmp_path):
        config = _three_host_config(tmp_path)
        argv = container.build_subcommand_args(
            config, ["linux"], _args(check_tools=False), repo_root="."
        )
        assert "--no-check-tools" in argv

    def test_flutter_args_forwarded(self, tmp_path):
        config = _three_host_config(tmp_path)
        argv = container.build_subcommand_args(
            config, ["linux"], _args(flutter_arg=["--verbose"]), repo_root="."
        )
        assert argv.count("--flutter-arg") == 1
        assert "--verbose" in argv


# ---------------------------------------------------------------------------
# docker argv
# ---------------------------------------------------------------------------


class TestDockerArgv:
    def _endpoint(self):
        return {"kind": "docker", "image": "img:latest", "workdir": "/work"}

    def test_bind_mounts_and_image(self, tmp_path):
        config = _three_host_config(tmp_path)
        argv = container.docker_argv(config, ["linux"], self._endpoint(), STAMP, _args())
        assert argv[0] == "docker"
        assert "run" in argv and "--rm" in argv
        joined = " ".join(argv)
        assert f"{config.repo_root}:/work" in joined
        assert "/opt/cepheus-build:ro" in joined
        assert "img:latest" in argv

    def test_injects_gowork_off_and_stamp(self, tmp_path):
        config = _three_host_config(tmp_path)
        argv = container.docker_argv(config, ["linux"], self._endpoint(), STAMP, _args())
        assert "GOWORK=off" in argv
        assert "CBUILD_VERSION=26.6.11" in argv

    def test_inner_invocation_is_local_mode(self, tmp_path):
        config = _three_host_config(tmp_path)
        argv = container.docker_argv(config, ["linux"], self._endpoint(), STAMP, _args())
        joined = " ".join(argv)
        assert "/opt/cepheus-build/bin/cepheus-build build -p demo linux" in joined
        assert "--execution-mode local --no-sync" in joined

    def test_missing_image_raises(self, tmp_path):
        config = _three_host_config(tmp_path)
        with pytest.raises(BuildError):
            container.docker_argv(config, ["linux"], {"kind": "docker"}, STAMP, _args())

    def test_remote_engine_fails_closed(self, tmp_path):
        # A remote docker engine would resolve the bind-mount paths on ITS
        # filesystem -- the wrong tree. kind = "ssh" is the remote transport.
        config = _three_host_config(tmp_path)
        endpoint = {**self._endpoint(), "host": "ssh://build@remote"}
        with pytest.raises(BuildError, match="remote engine"):
            container.docker_argv(config, ["linux"], endpoint, STAMP, _args())

    def test_forwarded_env_is_name_only(self, tmp_path, monkeypatch):
        # Secret VALUES must not appear in the echoed docker argv; docker
        # reads name-only -e vars from the client process environment.
        config = _config(
            tmp_path,
            """\
            [flutter.dart_defines]
            API_KEY = { env = "DEMO_SECRET", default = "" }

            [targets.linux]
            hosts = ["linux"]
            commands = ["make linux"]
            artifacts = ["build/linux"]
            """,
        )
        monkeypatch.setenv("DEMO_SECRET", "hunter2")
        argv = container.docker_argv(config, ["linux"], self._endpoint(), STAMP, _args())
        assert "DEMO_SECRET" in argv
        assert not any("hunter2" in part for part in argv)


# ---------------------------------------------------------------------------
# remote command (ssh)
# ---------------------------------------------------------------------------


class TestRemoteCommand:
    def test_posix_structure(self):
        cmd = container.remote_command(
            "posix",
            "~/cbuild/demo",
            [("CBUILD_VERSION", "26.6.11")],
            "~/cepheus-build/bin/cepheus-build",
            ["build", "-p", "demo", "macos"],
        )
        # Tilde expands to $HOME (not quoted) so the remote shell resolves it.
        assert 'cd "$HOME"/cbuild/demo' in cmd
        assert "CBUILD_VERSION=26.6.11" in cmd
        assert '"$HOME"/cepheus-build/bin/cepheus-build build -p demo macos' in cmd

    def test_powershell_uses_call_operator(self):
        cmd = container.remote_command(
            "powershell",
            "~/cbuild/demo",
            [("CBUILD_VERSION", "26.6.11")],
            "python ~/cepheus-build/bin/cepheus-build",
            ["build", "-p", "demo", "windows"],
        )
        # Errors must terminate: ';' chains regardless of failure, so a failed
        # cd would otherwise run the build in the wrong directory.
        assert cmd.startswith("$ErrorActionPreference = 'Stop'; cd ")
        # PowerShell needs '&' to invoke a path/quoted command.
        assert "& 'python'" in cmd
        assert "$env:CBUILD_VERSION = '26.6.11'" in cmd
        assert '$env:USERPROFILE/cepheus-build/bin/cepheus-build' in cmd

    def test_powershell_backslash_launcher_normalized(self):
        cmd = container.remote_command(
            "powershell",
            "~/cbuild/demo",
            [],
            r"C:\Python312\python.exe ~/cepheus-build/bin/cepheus-build",
            ["build"],
        )
        # shlex.split would have eaten the backslashes as escapes.
        assert "'C:/Python312/python.exe'" in cmd

    def test_posix_no_env_pairs(self):
        cmd = container.remote_command(
            "posix", "/abs/demo", [], "cepheus-build", ["build", "-p", "demo", "macos"]
        )
        assert cmd.startswith("cd /abs/demo && cepheus-build build")


# ---------------------------------------------------------------------------
# rsync argv
# ---------------------------------------------------------------------------


class TestRsyncArgv:
    def test_push_excludes_overrides_and_output_trees(self):
        argv = container.rsync_push_argv("u@h:cbuild/demo", ["-p", "2222"])
        joined = " ".join(argv)
        assert "--delete" in argv
        assert "pubspec_overrides.yaml" in joined
        assert "go.work" in joined
        for output_tree in ("build/", "target/", "dist/"):
            assert ["--exclude", output_tree] == argv[argv.index(output_tree) - 1 : argv.index(output_tree) + 1]
        assert "-e" in argv and "ssh -p 2222" in joined

    def test_push_source_is_cwd_relative(self):
        # The caller runs rsync with cwd=repo_root: a ``./`` source keeps
        # Windows drive-letter paths (D:/...) out of the argv, where rsync
        # would parse the colon as a host separator.
        argv = container.rsync_push_argv("u@h:cbuild/demo", [])
        assert argv[-2] == "./"
        assert argv[-1] == "u@h:cbuild/demo/"

    def test_transport_is_batch_mode(self):
        argv = container.rsync_push_argv("u@h:cbuild/demo", ["-p", "2222"])
        transport = argv[argv.index("-e") + 1]
        assert transport.startswith("ssh -p 2222")
        assert "BatchMode=yes" in transport
        assert "StrictHostKeyChecking=accept-new" in transport

    def test_transport_ssh_pin(self):
        # MSYS2/Cygwin rsync on Windows cannot drive the native Win32-OpenSSH
        # ssh.exe; rsync_ssh pins a compatible ssh for the -e transport only.
        endpoint = {"rsync_ssh": "C:/msys64/usr/bin/ssh.exe"}
        argv = container.rsync_pull_argv("u@h", "cbuild/demo", "build", [], endpoint)
        transport = argv[argv.index("-e") + 1]
        assert transport.startswith("C:/msys64/usr/bin/ssh.exe")

    def test_transport_prefers_sibling_ssh_over_plain(self, monkeypatch, tmp_path):
        # With no rsync_ssh pin, the ssh co-located with rsync wins on Windows
        # (cwRsync/MSYS2 ship a matching pair); plain "ssh" is the fallback.
        sibling = tmp_path / "ssh.exe"
        sibling.write_bytes(b"")
        monkeypatch.setattr(container.os, "name", "nt")
        monkeypatch.setattr(
            container.shutil, "which", lambda name: str(tmp_path / "rsync.exe")
        )
        transport = container._rsync_transport({}, [])
        assert transport.startswith(sibling.as_posix())

    def test_transport_plain_ssh_when_no_sibling(self, monkeypatch):
        monkeypatch.setattr(container.shutil, "which", lambda name: None)
        transport = container._rsync_transport({}, [])
        assert transport.startswith("ssh ")

    def test_pull_is_relative_with_anchor(self):
        argv = container.rsync_pull_argv("u@h", "cbuild/demo", "build/macos", [])
        assert "--relative" in argv
        assert argv[-2] == "u@h:cbuild/demo/./build/macos"
        assert argv[-1] == "."


# ---------------------------------------------------------------------------
# artifact pull roots
# ---------------------------------------------------------------------------


class TestArtifactPullRoots:
    def test_glob_file_yields_parent_dir(self):
        assert container._glob_free_root("build/macos/printdeck-*-macos.dmg") == "build/macos"

    def test_literal_path_returned_whole(self):
        assert (
            container._glob_free_root("target/x86_64-unknown-linux-gnu/release/foundry")
            == "target/x86_64-unknown-linux-gnu/release/foundry"
        )

    def test_first_segment_glob_yields_none(self):
        assert container._glob_free_root("*/dist") is None

    def test_question_mark_and_brackets_are_globs(self):
        assert container._glob_free_root("dist/v?/app") == "dist"
        assert container._glob_free_root("dist/[ab]/app") == "dist"

    def test_roots_union_across_targets(self, tmp_path):
        config = _three_host_config(tmp_path)
        roots = container.artifact_pull_roots(config, ["macos", "windows"])
        assert roots == [
            "build/macos/Build/Products/Release/demo.app",
            "dist/macos",
            "packaging/windows/dist",
        ]

    def test_nested_roots_collapse_into_ancestor(self, tmp_path):
        config = _config(
            tmp_path,
            """\
            [targets.linux]
            hosts = ["linux"]
            commands = ["make linux"]
            artifacts = ["build/linux/x64/release/bundle", "build/linux/demo-*.deb", "build/linux"]
            """,
        )
        assert container.artifact_pull_roots(config, ["linux"]) == ["build/linux"]

    def test_no_artifacts_warns_and_returns_empty(self, tmp_path, capsys):
        config = _config(
            tmp_path,
            """\
            [targets.macos]
            hosts = ["macos"]
            commands = ["make macos"]
            """,
        )
        assert container.artifact_pull_roots(config, ["macos"]) == []
        assert "declares no artifacts" in capsys.readouterr().out

    def test_absolute_artifact_skipped(self, tmp_path, capsys):
        config = _config(
            tmp_path,
            """\
            [targets.macos]
            hosts = ["macos"]
            commands = ["make macos"]
            artifacts = ["/tmp/out.dmg", "C:/out/demo.msix", "dist/demo.dmg"]
            """,
        )
        assert container.artifact_pull_roots(config, ["macos"]) == ["dist/demo.dmg"]
        assert "is absolute" in capsys.readouterr().out


# ---------------------------------------------------------------------------
# tilde path helpers
# ---------------------------------------------------------------------------


class TestPathHelpers:
    def test_posix_home_expansion(self):
        assert container._posix_path("~/a/b") == '"$HOME"/a/b'
        assert container._posix_path("~") == '"$HOME"'

    def test_posix_absolute_is_quoted(self):
        assert container._posix_path("/opt/x") == "/opt/x"

    def test_ps_home_expansion(self):
        assert container._ps_path("~/a/b") == '"$env:USERPROFILE/a/b"'

    def test_ps_absolute_is_single_quoted(self):
        assert container._ps_path("C:/x") == "'C:/x'"

    def test_ps_tail_neutralizes_expansion(self):
        # $ and backtick inside the double-quoted tail must not expand.
        assert container._ps_path("~/a$b") == '"$env:USERPROFILE/a`$b"'
        assert container._ps_path("~/a`b") == '"$env:USERPROFILE/a``b"'

    def test_rsync_remote_path_strips_tilde(self):
        assert container._rsync_remote_path("~/cbuild/demo") == "cbuild/demo"
        assert container._rsync_remote_path("~") == "."
        assert container._rsync_remote_path("/srv/cbuild") == "/srv/cbuild"

    def test_ssh_base_rejects_option_like_tokens(self):
        with pytest.raises(BuildError):
            container._ssh_base({"user": "-oProxyCommand=evil", "host": "h"}, host_override=None)
        with pytest.raises(BuildError):
            container._ssh_base({"user": "u", "host": "-evil"}, host_override=None)


# ---------------------------------------------------------------------------
# remote prepare + shell validation
# ---------------------------------------------------------------------------


class TestRemotePrepare:
    def test_posix_mkdir_and_stale_root_clean(self):
        cmd = container.remote_prepare_command(
            "posix", "~/cbuild/demo", ["build/macos", "dist/macos"]
        )
        assert cmd.startswith('mkdir -p "$HOME"/cbuild/demo')
        assert 'rm -rf "$HOME"/cbuild/demo/build/macos "$HOME"/cbuild/demo/dist/macos' in cmd

    def test_posix_no_roots_is_mkdir_only(self):
        cmd = container.remote_prepare_command("posix", "~/cbuild/demo", [])
        assert cmd == 'mkdir -p "$HOME"/cbuild/demo'

    def test_powershell_new_item_and_remove(self):
        cmd = container.remote_prepare_command(
            "powershell", "~/cbuild/demo", ["packaging/windows/dist"]
        )
        assert "New-Item -ItemType Directory -Force" in cmd
        assert "$env:USERPROFILE/cbuild/demo" in cmd
        assert "Remove-Item -Recurse -Force -ErrorAction SilentlyContinue" in cmd
        assert "$env:USERPROFILE/cbuild/demo/packaging/windows/dist" in cmd

    def test_unknown_shell_raises(self):
        with pytest.raises(BuildError):
            container.remote_prepare_command("powershel", "~/cbuild/demo", [])


class TestRemoteShellValidation:
    def test_remote_command_rejects_unknown_shell(self):
        with pytest.raises(BuildError):
            container.remote_command("bash", "/repo", [], "cli", ["build"])

    def test_endpoint_shell_validated(self):
        with pytest.raises(BuildError):
            container._remote_shell("windows", {"shell": "cmd"})

    def test_endpoint_shell_defaults_by_os(self):
        assert container._remote_shell("windows", {}) == "powershell"
        assert container._remote_shell("macos", {}) == "posix"


# ---------------------------------------------------------------------------
# cmd_container_build dispatch (run_argv recorded)
# ---------------------------------------------------------------------------


@pytest.fixture
def recorded(monkeypatch):
    """Record every run_argv dispatch as (argv, cwd)."""
    calls: list[tuple[list[str], object]] = []

    def fake_run_argv(argv, cwd, env, dry_run=False, *, prefix="", redact=None):
        calls.append((list(argv), cwd))

    monkeypatch.setattr(container, "run_argv", fake_run_argv)
    return calls


class TestCmdContainerBuild:
    def test_linux_dispatches_docker(self, tmp_path, recorded):
        config = _three_host_config(tmp_path)
        rc = container.cmd_container_build(config, _args(targets=["linux"]))
        assert rc == 0
        assert len(recorded) == 1
        assert recorded[0][0][:3] == ["docker", "run", "--rm"]

    def test_ssh_host_does_prepare_push_build_pulls(self, tmp_path, recorded):
        config = _three_host_config(tmp_path)
        rc = container.cmd_container_build(config, _args(targets=["macos"]))
        assert rc == 0
        programs = [argv[0] for argv, _cwd in recorded]
        # prepare, push, build, then one pull per artifact root (macos has 2).
        assert programs == ["ssh", "rsync", "ssh", "rsync", "rsync"]
        prepare_argv = recorded[0][0]
        assert "mkdir -p" in prepare_argv[-1]
        assert "rm -rf" in prepare_argv[-1]  # stale declared-artifact roots
        # The remote build command travels as ONE argv element (no local shell
        # re-parses it -- reliable from native Windows too).
        build_argv = recorded[2][0]
        assert build_argv[-1].startswith("cd ")
        assert "--execution-mode local" in build_argv[-1]
        # Transport ssh runs non-interactive.
        assert "BatchMode=yes" in prepare_argv

    def test_rsync_runs_in_repo_root(self, tmp_path, recorded):
        config = _three_host_config(tmp_path)
        rc = container.cmd_container_build(config, _args(targets=["macos"]))
        assert rc == 0
        rsync_cwds = [cwd for argv, cwd in recorded if argv[0] == "rsync"]
        assert rsync_cwds == [config.repo_root] * 3

    def test_mixed_targets_group_per_host(self, tmp_path, recorded):
        config = _three_host_config(tmp_path)
        rc = container.cmd_container_build(
            config, _args(targets=["linux", "macos", "windows"])
        )
        assert rc == 0
        programs = [argv[0] for argv, _cwd in recorded]
        # 1 docker (linux); per ssh host: prepare + build (ssh), push + one
        # pull per root (rsync). macos has 2 roots, windows 1.
        assert programs.count("docker") == 1
        assert programs.count("rsync") == 5
        assert programs.count("ssh") == 4

    def test_unknown_profile_raises(self, tmp_path, recorded):
        config = _three_host_config(tmp_path)
        with pytest.raises(BuildError):
            container.cmd_container_build(config, _args(targets=["linux"], container_profile="ghost"))

    def test_pull_missing_roots_tolerated(self, tmp_path, monkeypatch, capsys):
        """rsync exit 23 on an artifact pull is a per-root warning, not a failure."""
        import subprocess as sp

        config = _three_host_config(tmp_path)

        def fake_run_argv(argv, cwd, env, dry_run=False, *, prefix="", redact=None):
            if argv[0] == "rsync" and "--relative" in argv:
                raise sp.CalledProcessError(23, "rsync")

        monkeypatch.setattr(container, "run_argv", fake_run_argv)
        rc = container.cmd_container_build(config, _args(targets=["macos"]))
        assert rc == 0
        out = capsys.readouterr().out
        assert out.count("rsync exit 23") == 2  # one warning per missing root

    def test_pull_real_rsync_error_still_fails(self, tmp_path, monkeypatch):
        import subprocess as sp

        config = _three_host_config(tmp_path)

        def fake_run_argv(argv, cwd, env, dry_run=False, *, prefix="", redact=None):
            if argv[0] == "rsync" and "--relative" in argv:
                raise sp.CalledProcessError(12, "rsync")

        monkeypatch.setattr(container, "run_argv", fake_run_argv)
        rc = container.cmd_container_build(config, _args(targets=["macos"]))
        assert rc == 1

    def test_ssh_secrets_redacted_via_run_argv(self, tmp_path, monkeypatch):
        """Forwarded dart_define env values ride to run_argv as redact targets."""
        config = _config(
            tmp_path,
            """\
            [flutter.dart_defines]
            API_KEY = { env = "DEMO_SECRET", default = "" }

            [targets.macos]
            hosts = ["macos"]
            commands = ["make macos"]
            artifacts = ["dist/demo.dmg"]
            """,
        )
        monkeypatch.setenv("DEMO_SECRET", "hunter2")
        redactions: list[list[str]] = []

        def fake_run_argv(argv, cwd, env, dry_run=False, *, prefix="", redact=None):
            redactions.append(list(redact or []))

        monkeypatch.setattr(container, "run_argv", fake_run_argv)
        rc = container.cmd_container_build(config, _args(targets=["macos"]))
        assert rc == 0
        # Exactly the build step (3rd call) carries the secret for redaction.
        assert redactions[2] == ["hunter2"]

    def test_missing_transport_tool_fails_fast(self, tmp_path, monkeypatch, recorded):
        config = _three_host_config(tmp_path)
        monkeypatch.setattr(
            container, "tool_status", lambda tool: (tool != "rsync", "not found")
        )
        with pytest.raises(BuildError, match="rsync"):
            container.cmd_container_build(config, _args(targets=["macos"]))
        assert recorded == []  # nothing dispatched

    def test_dry_run_skips_transport_tool_check(self, tmp_path, monkeypatch, recorded):
        config = _three_host_config(tmp_path)
        monkeypatch.setattr(container, "tool_status", lambda tool: (False, "not found"))
        rc = container.cmd_container_build(config, _args(targets=["macos"], dry_run=True))
        assert rc == 0


class TestParallelDispatch:
    def test_parallel_prefixes_per_host(self, tmp_path, monkeypatch):
        config = _three_host_config(tmp_path)
        prefixes: list[str] = []

        def fake_run_argv(argv, cwd, env, dry_run=False, *, prefix="", redact=None):
            prefixes.append(prefix)

        monkeypatch.setattr(container, "run_argv", fake_run_argv)
        rc = container.cmd_container_build(
            config, _args(targets=["linux", "macos", "windows"])
        )
        assert rc == 0
        assert set(prefixes) == {"[linux] ", "[macos] ", "[windows] "}

    def test_parallel_aggregates_failures_across_hosts(self, tmp_path, monkeypatch, capsys):
        import subprocess as sp

        config = _three_host_config(tmp_path)

        def fake_run_argv(argv, cwd, env, dry_run=False, *, prefix="", redact=None):
            if argv[0] == "ssh":
                raise sp.CalledProcessError(255, "ssh")

        monkeypatch.setattr(container, "run_argv", fake_run_argv)
        rc = container.cmd_container_build(
            config, _args(targets=["linux", "macos", "windows"])
        )
        assert rc == 1
        out = capsys.readouterr().out
        # Both ssh hosts failed; the docker (linux) host is not in the summary.
        assert "macos: macos" in out
        assert "windows: windows" in out
        assert "linux: linux" not in out

    def test_no_keep_going_is_sequential_and_stops(self, tmp_path, monkeypatch):
        import subprocess as sp

        config = _three_host_config(tmp_path)
        calls: list[str] = []

        def fake_run_argv(argv, cwd, env, dry_run=False, *, prefix="", redact=None):
            calls.append(argv[0])
            raise sp.CalledProcessError(1, argv[0])

        monkeypatch.setattr(container, "run_argv", fake_run_argv)
        rc = container.cmd_container_build(
            config,
            _args(targets=["linux", "macos", "windows"], keep_going=False),
        )
        assert rc == 1
        # Stopped after the first host group (linux's single docker call).
        assert calls == ["docker"]

    def test_dry_run_is_sequential_without_prefixes(self, tmp_path, monkeypatch):
        config = _three_host_config(tmp_path)
        prefixes: list[str] = []

        def fake_run_argv(argv, cwd, env, dry_run=False, *, prefix="", redact=None):
            prefixes.append(prefix)

        monkeypatch.setattr(container, "run_argv", fake_run_argv)
        rc = container.cmd_container_build(
            config, _args(targets=["linux", "macos", "windows"], dry_run=True)
        )
        assert rc == 0
        assert set(prefixes) == {""}

    def test_opt_out_flag_is_sequential(self, tmp_path, monkeypatch):
        config = _three_host_config(tmp_path)
        prefixes: list[str] = []

        def fake_run_argv(argv, cwd, env, dry_run=False, *, prefix="", redact=None):
            prefixes.append(prefix)

        monkeypatch.setattr(container, "run_argv", fake_run_argv)
        rc = container.cmd_container_build(
            config,
            _args(targets=["linux", "macos", "windows"], parallel_hosts=False),
        )
        assert rc == 0
        assert set(prefixes) == {""}
