"""Tests for cepheus_build.github: github_repo_from_remote, build_ci_matrix, preferred_host."""

from __future__ import annotations

import textwrap
from pathlib import Path

import pytest

from cepheus_build.config import ProductConfig, load_toml
from cepheus_build.errors import BuildError
from cepheus_build.github import (
    build_ci_matrix,
    github_repo_from_remote,
    preferred_host_for_target,
    runner_profile_names,
)

# ---------------------------------------------------------------------------
# github_repo_from_remote()
# ---------------------------------------------------------------------------

class TestGithubRepoFromRemote:
    def test_https_url(self):
        assert github_repo_from_remote("https://github.com/org/repo") == "org/repo"

    def test_https_url_with_git_suffix(self):
        assert github_repo_from_remote("https://github.com/org/repo.git") == "org/repo"

    def test_https_url_with_trailing_slash(self):
        assert github_repo_from_remote("https://github.com/org/repo/") == "org/repo"

    def test_git_at_url(self):
        assert github_repo_from_remote("git@github.com:org/repo") == "org/repo"

    def test_git_at_url_with_git_suffix(self):
        assert github_repo_from_remote("git@github.com:org/repo.git") == "org/repo"

    def test_ssh_url(self):
        assert github_repo_from_remote("ssh://git@github.com/org/repo") == "org/repo"

    def test_ssh_url_with_git_suffix(self):
        assert github_repo_from_remote("ssh://git@github.com/org/repo.git") == "org/repo"

    def test_non_github_url_returns_none(self):
        assert github_repo_from_remote("https://gitlab.com/org/repo") is None

    def test_arbitrary_string_returns_none(self):
        assert github_repo_from_remote("not-a-url") is None

    def test_empty_string_returns_none(self):
        assert github_repo_from_remote("") is None

    def test_leading_whitespace_stripped(self):
        assert github_repo_from_remote("  https://github.com/org/repo  ") == "org/repo"


# ---------------------------------------------------------------------------
# runner_profile_names()
# ---------------------------------------------------------------------------

class TestRunnerProfileNames:
    def test_returns_list(self):
        names = runner_profile_names()
        assert isinstance(names, list)

    def test_github_hosted_present(self):
        assert "github-hosted" in runner_profile_names()

    def test_self_hosted_present(self):
        assert "self-hosted" in runner_profile_names()

    def test_sorted(self):
        names = runner_profile_names()
        assert names == sorted(names)


# ---------------------------------------------------------------------------
# preferred_host_for_target()
# ---------------------------------------------------------------------------

class TestPreferredHostForTarget:
    def test_macos_only_target(self):
        target = {"hosts": ["macos"]}
        assert preferred_host_for_target("macos-build", target) == "macos"

    def test_linux_only_target(self):
        target = {"hosts": ["linux"]}
        assert preferred_host_for_target("web", target) == "linux"

    def test_multi_host_picks_first_in_order(self):
        # linux, macos, windows is HOST_ORDER; first available wins
        target = {"hosts": ["macos", "linux"]}
        host = preferred_host_for_target("cross", target)
        assert host in {"macos", "linux"}

    def test_ci_hosts_preference_honored(self):
        target = {"hosts": ["macos", "linux"], "ci_hosts": ["macos"]}
        assert preferred_host_for_target("ci-test", target) == "macos"

    def test_no_hosts_returns_linux_first(self):
        # normalize_hosts(None) -> all hosts; preferred from HOST_ORDER
        target = {}
        host = preferred_host_for_target("any", target)
        assert host == "linux"


# ---------------------------------------------------------------------------
# build_ci_matrix()
# ---------------------------------------------------------------------------

def _make_ci_config(tmp_path: Path) -> ProductConfig:
    toml_content = textwrap.dedent("""\
        [product]
        slug = "ciprod"
        display_name = "CI Prod"
        repo_root = "."

        [targets.web]
        hosts = ["linux", "macos", "windows"]
        tools = ["flutter", "go"]

        [targets.macos-app]
        hosts = ["macos"]
        tools = {macos = ["flutter", "cargo"], default = ["flutter"]}

        [targets.linux-deb]
        hosts = ["linux"]
        tools = ["flutter", "dpkg-deb"]

        [targets.linux-rpm]
        hosts = ["linux"]
        tools = ["flutter", "rpmbuild"]

        [targets.linux-flatpak]
        hosts = ["linux"]
        tools = ["flutter", "flatpak-builder"]

        [targets.windows-installer]
        hosts = ["windows"]
        tools = ["flutter", "iscc"]
    """)
    cfg_path = tmp_path / "ciprod.toml"
    cfg_path.write_text(toml_content)
    return ProductConfig(path=cfg_path, data=load_toml(cfg_path))


class TestBuildCiMatrix:
    def test_returns_include_key(self, tmp_path):
        config = _make_ci_config(tmp_path)
        matrix = build_ci_matrix(config, ["web"], "github-hosted")
        assert "include" in matrix

    def test_web_on_linux_preferred(self, tmp_path):
        config = _make_ci_config(tmp_path)
        matrix = build_ci_matrix(config, ["web"], "github-hosted")
        hosts = {row["host"] for row in matrix["include"]}
        # web has linux, macos, windows; linux is first in HOST_ORDER
        assert "linux" in hosts

    def test_macos_app_goes_to_macos_row(self, tmp_path):
        config = _make_ci_config(tmp_path)
        matrix = build_ci_matrix(config, ["macos-app"], "github-hosted")
        hosts = {row["host"] for row in matrix["include"]}
        assert hosts == {"macos"}

    def test_setup_flutter_true_when_flutter_in_tools(self, tmp_path):
        config = _make_ci_config(tmp_path)
        matrix = build_ci_matrix(config, ["web"], "github-hosted")
        linux_rows = [r for r in matrix["include"] if r["host"] == "linux"]
        assert linux_rows
        assert linux_rows[0]["setup_flutter"] is True

    def test_setup_go_true_when_go_in_tools(self, tmp_path):
        config = _make_ci_config(tmp_path)
        matrix = build_ci_matrix(config, ["web"], "github-hosted")
        linux_rows = [r for r in matrix["include"] if r["host"] == "linux"]
        assert linux_rows[0]["setup_go"] is True

    def test_setup_rust_true_when_cargo_in_tools(self, tmp_path):
        config = _make_ci_config(tmp_path)
        matrix = build_ci_matrix(config, ["macos-app"], "github-hosted")
        macos_rows = [r for r in matrix["include"] if r["host"] == "macos"]
        # macos tools include cargo
        assert macos_rows[0]["setup_rust"] is True

    def test_runner_is_string_or_list(self, tmp_path):
        config = _make_ci_config(tmp_path)
        matrix = build_ci_matrix(config, ["web"], "github-hosted")
        for row in matrix["include"]:
            assert isinstance(row["runner"], (str, list))

    def test_invalid_profile_raises(self, tmp_path):
        config = _make_ci_config(tmp_path)
        with pytest.raises(BuildError):
            build_ci_matrix(config, ["web"], "nonexistent-profile")

    def test_targets_field_contains_target_name(self, tmp_path):
        config = _make_ci_config(tmp_path)
        matrix = build_ci_matrix(config, ["macos-app"], "github-hosted")
        macos_rows = [r for r in matrix["include"] if r["host"] == "macos"]
        assert "macos-app" in macos_rows[0]["targets"]

    # --- packaging toolchain setup flags -----------------------------------

    def test_setup_deb_true_for_deb_target(self, tmp_path):
        config = _make_ci_config(tmp_path)
        matrix = build_ci_matrix(config, ["linux-deb"], "github-hosted")
        row = next(r for r in matrix["include"] if r["host"] == "linux")
        assert row["setup_deb"] is True
        assert row["setup_rpm"] is False
        assert row["setup_flatpak"] is False

    def test_setup_rpm_true_for_rpm_target(self, tmp_path):
        config = _make_ci_config(tmp_path)
        matrix = build_ci_matrix(config, ["linux-rpm"], "github-hosted")
        row = next(r for r in matrix["include"] if r["host"] == "linux")
        assert row["setup_rpm"] is True
        assert row["setup_deb"] is False

    def test_setup_flatpak_true_for_flatpak_target(self, tmp_path):
        config = _make_ci_config(tmp_path)
        matrix = build_ci_matrix(config, ["linux-flatpak"], "github-hosted")
        row = next(r for r in matrix["include"] if r["host"] == "linux")
        assert row["setup_flatpak"] is True

    def test_setup_innosetup_true_for_windows_installer(self, tmp_path):
        config = _make_ci_config(tmp_path)
        matrix = build_ci_matrix(config, ["windows-installer"], "github-hosted")
        row = next(r for r in matrix["include"] if r["host"] == "windows")
        assert row["setup_innosetup"] is True

    def test_packaging_flags_absent_by_default(self, tmp_path):
        # A plain target (no packaging tools) leaves every new flag False, so
        # CI installs nothing extra for ordinary build rows.
        config = _make_ci_config(tmp_path)
        matrix = build_ci_matrix(config, ["web"], "github-hosted")
        for row in matrix["include"]:
            assert row["setup_deb"] is False
            assert row["setup_rpm"] is False
            assert row["setup_flatpak"] is False
            assert row["setup_innosetup"] is False

    def test_deb_and_rpm_share_one_linux_row(self, tmp_path):
        # Both Linux package targets collapse onto the single linux row, which
        # then advertises both toolchains — mirrors how desktop_packages builds.
        config = _make_ci_config(tmp_path)
        matrix = build_ci_matrix(config, ["linux-deb", "linux-rpm"], "github-hosted")
        linux_rows = [r for r in matrix["include"] if r["host"] == "linux"]
        assert len(linux_rows) == 1
        assert linux_rows[0]["setup_deb"] is True
        assert linux_rows[0]["setup_rpm"] is True
