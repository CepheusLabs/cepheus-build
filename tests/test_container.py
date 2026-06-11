"""Tests for cepheus_build.container: profile lookup, routing, argv builders.

The argv/command builders are pure functions, so they are asserted directly
(OS-independent). ``cmd_container_build`` is exercised with ``run_command``
monkeypatched to record the dispatched command strings instead of running a
shell, mirroring tests/test_builder.py.
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
        targets=None,
    )
    base.update(overrides)
    return SimpleNamespace(**base)


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

    def test_container_host_override(self, tmp_path):
        config = _three_host_config(tmp_path)
        argv = container.docker_argv(
            config, ["linux"], self._endpoint(), STAMP, _args(),
            docker_host="ssh://build@remote",
        )
        assert "--host" in argv
        assert "ssh://build@remote" in argv


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
        # PowerShell needs '&' to invoke a path/quoted command.
        assert "& 'python'" in cmd
        assert "$env:CBUILD_VERSION = '26.6.11'" in cmd
        assert '$env:USERPROFILE/cepheus-build/bin/cepheus-build' in cmd

    def test_posix_no_env_pairs(self):
        cmd = container.remote_command(
            "posix", "/abs/demo", [], "cepheus-build", ["build", "-p", "demo", "macos"]
        )
        assert cmd.startswith("cd /abs/demo && cepheus-build build")


# ---------------------------------------------------------------------------
# rsync argv
# ---------------------------------------------------------------------------


class TestRsyncArgv:
    def test_push_excludes_overrides(self):
        argv = container.rsync_push_argv("u@h:cbuild/demo", ["-p", "2222"])
        joined = " ".join(argv)
        assert "--delete" in argv
        assert "pubspec_overrides.yaml" in joined
        assert "go.work" in joined
        assert "build/" in joined
        assert "-e" in argv and "ssh -p 2222" in joined

    def test_push_source_is_cwd_relative(self):
        # The caller runs rsync with cwd=repo_root: a ``./`` source keeps
        # Windows drive-letter paths (D:/...) out of the argv, where rsync
        # would parse the colon as a host separator.
        argv = container.rsync_push_argv("u@h:cbuild/demo", [])
        assert argv[-2] == "./"
        assert argv[-1] == "u@h:cbuild/demo/"

    def test_pull_is_relative_with_anchor(self):
        argv = container.rsync_pull_argv("u@h", "cbuild/demo", ["build/macos"], [])
        assert "--relative" in argv
        assert argv[-2] == "u@h:cbuild/demo/./build/macos"
        assert argv[-1] == "."

    def test_pull_multiple_roots_share_one_connection(self):
        argv = container.rsync_pull_argv(
            "u@h", "cbuild/demo", ["build/macos", "dist/macos"], []
        )
        # rsync source args after the first may omit the host part.
        assert "u@h:cbuild/demo/./build/macos" in argv
        assert ":cbuild/demo/./dist/macos" in argv

    def test_pull_no_roots_raises(self):
        with pytest.raises(BuildError):
            container.rsync_pull_argv("u@h", "cbuild/demo", [], [])


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

    def test_rsync_remote_path_strips_tilde(self):
        assert container._rsync_remote_path("~/cbuild/demo") == "cbuild/demo"
        assert container._rsync_remote_path("~") == "."
        assert container._rsync_remote_path("/srv/cbuild") == "/srv/cbuild"


# ---------------------------------------------------------------------------
# remote mkdir + shell validation
# ---------------------------------------------------------------------------


class TestRemoteMkdir:
    def test_posix_mkdir_p(self):
        cmd = container.remote_mkdir_command("posix", "~/cbuild/demo")
        assert cmd == 'mkdir -p "$HOME"/cbuild/demo'

    def test_powershell_new_item(self):
        cmd = container.remote_mkdir_command("powershell", "~/cbuild/demo")
        assert "New-Item -ItemType Directory -Force" in cmd
        assert "$env:USERPROFILE/cbuild/demo" in cmd

    def test_unknown_shell_raises(self):
        with pytest.raises(BuildError):
            container.remote_mkdir_command("powershel", "~/cbuild/demo")


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
# cmd_container_build dispatch (run_command recorded)
# ---------------------------------------------------------------------------


@pytest.fixture
def recorded(monkeypatch):
    """Record every run_argv dispatch as (argv, cwd)."""
    calls: list[tuple[list[str], object]] = []

    def fake_run_argv(argv, cwd, env, dry_run=False, *, prefix=""):
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

    def test_ssh_host_does_mkdir_push_build_pull(self, tmp_path, recorded):
        config = _three_host_config(tmp_path)
        rc = container.cmd_container_build(config, _args(targets=["macos"]))
        assert rc == 0
        programs = [argv[0] for argv, _cwd in recorded]
        assert programs == ["ssh", "rsync", "ssh", "rsync"]
        mkdir_argv = recorded[0][0]
        assert "mkdir -p" in mkdir_argv[-1]
        # The remote build command travels as ONE argv element (no local shell
        # re-parses it -- reliable from native Windows too).
        build_argv = recorded[2][0]
        assert build_argv[-1].startswith("cd ")
        assert "--execution-mode local" in build_argv[-1]

    def test_rsync_runs_in_repo_root(self, tmp_path, recorded):
        config = _three_host_config(tmp_path)
        rc = container.cmd_container_build(config, _args(targets=["macos"]))
        assert rc == 0
        rsync_cwds = [cwd for argv, cwd in recorded if argv[0] == "rsync"]
        assert rsync_cwds == [config.repo_root, config.repo_root]

    def test_mixed_targets_group_per_host(self, tmp_path, recorded):
        config = _three_host_config(tmp_path)
        rc = container.cmd_container_build(
            config, _args(targets=["linux", "macos", "windows"])
        )
        assert rc == 0
        programs = [argv[0] for argv, _cwd in recorded]
        # 1 docker (linux) + 4 ssh-steps (macos) + 4 ssh-steps (windows)
        assert programs.count("docker") == 1
        assert programs.count("rsync") == 4
        assert programs.count("ssh") == 4

    def test_unknown_profile_raises(self, tmp_path, recorded):
        config = _three_host_config(tmp_path)
        with pytest.raises(BuildError):
            container.cmd_container_build(config, _args(targets=["linux"], container_profile="ghost"))

    def test_pull_missing_roots_tolerated(self, tmp_path, monkeypatch, capsys):
        """rsync exit 23 on the artifact pull is a warning, not a failure."""
        import subprocess as sp

        config = _three_host_config(tmp_path)

        def fake_run_argv(argv, cwd, env, dry_run=False, *, prefix=""):
            if argv[0] == "rsync" and "--relative" in argv:
                raise sp.CalledProcessError(23, "rsync")

        monkeypatch.setattr(container, "run_argv", fake_run_argv)
        rc = container.cmd_container_build(config, _args(targets=["macos"]))
        assert rc == 0
        assert "rsync exit 23" in capsys.readouterr().out

    def test_pull_real_rsync_error_still_fails(self, tmp_path, monkeypatch):
        import subprocess as sp

        config = _three_host_config(tmp_path)

        def fake_run_argv(argv, cwd, env, dry_run=False, *, prefix=""):
            if argv[0] == "rsync" and "--relative" in argv:
                raise sp.CalledProcessError(12, "rsync")

        monkeypatch.setattr(container, "run_argv", fake_run_argv)
        rc = container.cmd_container_build(config, _args(targets=["macos"]))
        assert rc == 1
