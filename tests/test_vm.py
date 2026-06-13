"""Tests for cepheus_build.vm: compose argv synthesis, SSH probing, wait loop."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from cepheus_build import vm
from cepheus_build.errors import BuildError

WINDOWS_EP = {"kind": "ssh", "host": "192.168.0.98", "port": 2322, "user": "cbuild"}
MACOS_EP = {"kind": "ssh", "host": "192.168.0.98", "port": 2422, "user": "cbuild"}
LINUX_BUILDER_EP = {
    "kind": "ssh", "host": "192.168.0.98", "port": 2522, "user": "builder",
    "compose_service": "linux-builder",
}
PROFILE = {
    "label": "pool",
    "linux": {"kind": "docker", "image": "img"},
    "windows": WINDOWS_EP,
    "macos": MACOS_EP,
    "compose": {"host": "192.168.0.98", "user": "errai", "dir": "~/cepheus-build/docker"},
}
ERRAI_PROFILE = {
    "label": "errai",
    "linux": LINUX_BUILDER_EP,
    "windows": WINDOWS_EP,
    "macos": MACOS_EP,
    "compose": {"host": "192.168.0.98", "user": "errai", "dir": "~/cepheus-build/docker"},
}


def _args(**overrides) -> SimpleNamespace:
    base = dict(
        vm_action="status",
        services=[],
        container_profile="default",
        wait=True,
        wait_timeout=1200,
        dry_run=False,
    )
    base.update(overrides)
    return SimpleNamespace(**base)


# ---------------------------------------------------------------------------
# compose argv
# ---------------------------------------------------------------------------


class TestComposeArgv:
    def test_local_when_no_host(self):
        argv, cwd = vm.compose_argv({}, ["up", "-d", "windows"])
        assert argv == ["docker", "compose", "up", "-d", "windows"]
        assert cwd is not None and cwd.name == "docker"

    def test_remote_wraps_in_ssh(self):
        argv, cwd = vm.compose_argv(
            {"host": "192.168.0.98", "user": "errai", "dir": "~/cepheus-build/docker"},
            ["up", "-d", "windows", "macos"],
        )
        assert cwd is None
        assert argv[0] == "ssh"
        assert "BatchMode=yes" in argv
        assert argv[-2] == "errai@192.168.0.98"
        remote = argv[-1]
        # ~ expands on the REMOTE side ($HOME), never the dispatch host.
        assert remote.startswith('cd "$HOME"/cepheus-build/docker && docker compose')
        assert remote.endswith("up -d windows macos")

    def test_remote_port_option(self):
        argv, _cwd = vm.compose_argv({"host": "h", "port": 2222}, ["ps"])
        assert argv[:3] == ["ssh", "-p", "2222"]

    def test_option_like_host_rejected(self):
        with pytest.raises(BuildError):
            vm.compose_argv({"host": "-oProxyCommand=evil"}, ["ps"])
        with pytest.raises(BuildError):
            vm.compose_argv({"host": "h", "user": "-bad"}, ["ps"])

    def test_remote_default_dir(self):
        argv, _cwd = vm.compose_argv({"host": "h"}, ["ps"])
        assert vm.DEFAULT_COMPOSE_DIR.replace("~/", "") in argv[-1]


# ---------------------------------------------------------------------------
# ssh probe argv + endpoint listing
# ---------------------------------------------------------------------------


class TestProbeArgv:
    def test_probe_is_batch_and_bounded(self):
        argv = vm.ssh_probe_argv(WINDOWS_EP)
        assert argv[0] == "ssh"
        assert "-p" in argv and "2322" in argv
        assert "BatchMode=yes" in argv
        assert any(opt.startswith("ConnectTimeout=") for opt in argv)
        assert argv[-2] == "cbuild@192.168.0.98"
        assert argv[-1] == "exit 0"


class TestSshEndpoints:
    def test_only_ssh_kind_in_host_order(self):
        endpoints = vm.ssh_endpoints(PROFILE)
        assert list(endpoints) == ["macos", "windows"]

    def test_errai_profile_includes_ssh_linux(self):
        # The errai profile's linux endpoint is kind=ssh (the builder), so it
        # joins the pool; the default profile's docker linux does not.
        assert list(vm.ssh_endpoints(ERRAI_PROFILE)) == ["linux", "macos", "windows"]

    def test_compose_table_is_not_an_endpoint(self):
        assert "compose" not in vm.ssh_endpoints(PROFILE)

    def test_endpoint_label(self):
        assert vm.endpoint_label(WINDOWS_EP) == "cbuild@192.168.0.98:2322"


class TestComposeService:
    def test_defaults_to_host_os(self):
        assert vm.compose_service_for("windows", WINDOWS_EP) == "windows"

    def test_override_used(self):
        assert vm.compose_service_for("linux", LINUX_BUILDER_EP) == "linux-builder"


# ---------------------------------------------------------------------------
# wait loop
# ---------------------------------------------------------------------------


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class TestWaitForSsh:
    def test_returns_when_all_ready(self, capsys):
        clock = FakeClock()
        attempts = {"windows": 0, "macos": 0}

        def probe(endpoint):
            host = "windows" if endpoint is WINDOWS_EP else "macos"
            attempts[host] += 1
            return (attempts[host] >= 3, "connection refused")

        vm.wait_for_ssh(
            {"windows": WINDOWS_EP, "macos": MACOS_EP},
            timeout=600,
            interval=15,
            probe=probe,
            clock=clock,
            sleep=clock.sleep,
        )
        out = capsys.readouterr().out
        assert "windows: ssh ready" in out
        assert "macos: ssh ready" in out

    def test_deadline_raises_with_reasons(self):
        clock = FakeClock()

        def probe(endpoint):
            return (False, "connection refused")

        with pytest.raises(BuildError) as excinfo:
            vm.wait_for_ssh(
                {"windows": WINDOWS_EP},
                timeout=60,
                interval=15,
                probe=probe,
                clock=clock,
                sleep=clock.sleep,
            )
        message = str(excinfo.value)
        assert "not ready after 60s" in message
        assert "connection refused" in message
        assert "noVNC" in message

    def test_partial_readiness_keeps_waiting_for_the_rest(self):
        clock = FakeClock()

        def probe(endpoint):
            return (endpoint is WINDOWS_EP, "still booting")

        with pytest.raises(BuildError) as excinfo:
            vm.wait_for_ssh(
                {"windows": WINDOWS_EP, "macos": MACOS_EP},
                timeout=30,
                interval=15,
                probe=probe,
                clock=clock,
                sleep=clock.sleep,
            )
        assert "macos" in str(excinfo.value)
        assert "windows" not in str(excinfo.value).split("--")[1]


# ---------------------------------------------------------------------------
# cmd_vm dispatch
# ---------------------------------------------------------------------------


@pytest.fixture
def fake_pool(monkeypatch):
    """Patch profile lookup, run_argv, and probes; record what runs."""
    recorded: dict[str, object] = {"argv": [], "probes": [], "waited": None}

    monkeypatch.setattr(vm, "container_profile_config", lambda name: PROFILE)
    monkeypatch.setattr(vm, "default_profile_name", lambda: "default")

    def fake_run_argv(argv, cwd, env, dry_run=False, *, prefix=""):
        recorded["argv"].append(list(argv))

    def fake_probe(endpoint):
        recorded["probes"].append(endpoint)
        return (True, "")

    def fake_wait(endpoints, *, timeout, **kwargs):
        recorded["waited"] = (sorted(endpoints), timeout)

    monkeypatch.setattr(vm, "run_argv", fake_run_argv)
    monkeypatch.setattr(vm, "probe_endpoint", fake_probe)
    monkeypatch.setattr(vm, "wait_for_ssh", fake_wait)
    return recorded


class TestCmdVm:
    def test_up_composes_and_waits(self, fake_pool):
        rc = vm.cmd_vm(_args(vm_action="up"))
        assert rc == 0
        remote = fake_pool["argv"][0][-1]
        assert "docker compose up -d macos windows" in remote
        assert fake_pool["waited"] == (["macos", "windows"], 1200)

    def test_up_no_wait(self, fake_pool):
        rc = vm.cmd_vm(_args(vm_action="up", wait=False))
        assert rc == 0
        assert fake_pool["waited"] is None

    def test_up_waits_only_for_requested_services(self, fake_pool):
        rc = vm.cmd_vm(_args(vm_action="up", services=["windows"]))
        assert rc == 0
        assert fake_pool["waited"] == (["windows"], 1200)

    def test_down_stops_not_down(self, fake_pool):
        rc = vm.cmd_vm(_args(vm_action="down"))
        assert rc == 0
        remote = fake_pool["argv"][0][-1]
        assert "docker compose stop" in remote
        assert " down" not in remote

    def test_status_probes_endpoints(self, fake_pool, capsys):
        rc = vm.cmd_vm(_args(vm_action="status"))
        assert rc == 0
        assert len(fake_pool["probes"]) == 2
        assert "ssh ready" in capsys.readouterr().out

    def test_status_unreachable_is_nonzero(self, fake_pool, monkeypatch):
        monkeypatch.setattr(vm, "probe_endpoint", lambda ep: (False, "refused"))
        rc = vm.cmd_vm(_args(vm_action="status"))
        assert rc == 1

    def test_dry_run_skips_probes_and_wait(self, fake_pool):
        rc = vm.cmd_vm(_args(vm_action="up", dry_run=True))
        assert rc == 0
        assert fake_pool["waited"] is None
        rc = vm.cmd_vm(_args(vm_action="status", dry_run=True))
        assert rc == 0
        assert fake_pool["probes"] == []

    def test_unknown_service_raises(self, fake_pool):
        with pytest.raises(BuildError, match="no ssh endpoint"):
            vm.cmd_vm(_args(vm_action="up", services=["bogus"]))


class TestCmdVmErrai:
    @pytest.fixture(autouse=True)
    def _errai(self, monkeypatch):
        recorded: dict[str, object] = {"argv": []}
        monkeypatch.setattr(vm, "container_profile_config", lambda name: ERRAI_PROFILE)
        monkeypatch.setattr(vm, "default_profile_name", lambda: "errai")
        monkeypatch.setattr(
            vm, "run_argv",
            lambda argv, cwd, env, dry_run=False, *, prefix="": recorded["argv"].append(list(argv)),
        )
        monkeypatch.setattr(vm, "probe_endpoint", lambda ep: (True, ""))
        monkeypatch.setattr(vm, "wait_for_ssh", lambda endpoints, *, timeout, **k: None)
        self.recorded = recorded

    def test_up_uses_linux_builder_compose_service(self):
        rc = vm.cmd_vm(_args(vm_action="up", container_profile="errai"))
        assert rc == 0
        remote = self.recorded["argv"][0][-1]
        # host-OS key 'linux' maps to the linux-builder container, not a bare
        # 'linux' service (which is the build-image stage).
        assert "docker compose up -d linux-builder macos windows" in remote

    def test_up_single_linux_maps_to_builder(self):
        rc = vm.cmd_vm(_args(vm_action="up", container_profile="errai", services=["linux"]))
        assert rc == 0
        assert "docker compose up -d linux-builder" in self.recorded["argv"][0][-1]
