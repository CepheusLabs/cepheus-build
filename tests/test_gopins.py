"""Tests for the gopins pseudo-version pin synchroniser (pure logic only)."""

from __future__ import annotations

from pathlib import Path

from cepheus_build import gopins

GO_MOD = """\
module github.com/CepheusLabs/printdeck-server

go 1.26.4

require (
\tgithub.com/cepheuslabs/apiutil v0.0.0-20260601120000-aaaaaaaaaaaa
\tgithub.com/cepheuslabs/gcode v0.0.0-20260601120000-bbbbbbbbbbbb
\tgithub.com/cepheuslabs/sqlkit v0.0.0-20260601120000-cccccccccccc // indirect
\tgithub.com/cepheuslabs/notreal v0.0.0-20260601120000-dddddddddddd
\tgithub.com/cepheuslabs/helm v1.2.3
\tgithub.com/google/uuid v1.6.0
)

// github.com/cepheuslabs/commentedout v0.0.0-20260601120000-eeeeeeeeeeee
"""

HEADS = {
    "apiutil": "aaaaaaaaaaaa" + "0" * 28,  # matches pin -> ok
    "gcode": "f" * 40,  # differs -> stale
    "sqlkit": "cccccccccccc" + "0" * 28,  # indirect, matches -> ok
    "helm": "1" * 40,  # non-pseudo pin -> non-pseudo
}


def fake_head(repo: Path) -> str | None:
    return HEADS.get(repo.name)


def test_parse_requires_filters_first_party_and_comments() -> None:
    requires = gopins.parse_requires(GO_MOD)
    modules = [module for module, _, _ in requires]
    assert "github.com/cepheuslabs/apiutil" in modules
    assert "github.com/cepheuslabs/helm" in modules
    assert "github.com/google/uuid" not in modules
    assert "github.com/cepheuslabs/commentedout" not in modules
    indirect = {module: ind for module, _, ind in requires}
    assert indirect["github.com/cepheuslabs/sqlkit"] is True
    assert indirect["github.com/cepheuslabs/apiutil"] is False


def test_pseudo_sha_variants() -> None:
    assert gopins.pseudo_sha("v0.0.0-20260601120000-abcdefabcdef") == "abcdefabcdef"
    assert gopins.pseudo_sha("v1.2.4-0.20260601120000-abcdefabcdef") == "abcdefabcdef"
    assert gopins.pseudo_sha("v1.2.3") is None
    assert gopins.pseudo_sha("v2.0.0+incompatible") is None


def test_plan_statuses(tmp_path: Path) -> None:
    rows = gopins.plan(GO_MOD, tmp_path, head_for=fake_head)
    by_module = {row.module.rsplit("/", 1)[-1]: row for row in rows}
    assert by_module["apiutil"].status == gopins.STATUS_OK
    assert by_module["gcode"].status == gopins.STATUS_STALE
    assert by_module["sqlkit"].status == gopins.STATUS_OK
    assert by_module["helm"].status == gopins.STATUS_NON_PSEUDO
    assert by_module["notreal"].status == gopins.STATUS_UNKNOWN_MODULE


def test_plan_missing_sibling(tmp_path: Path) -> None:
    rows = gopins.plan(
        "require github.com/cepheuslabs/apiutil v0.0.0-20260601120000-aaaaaaaaaaaa\n",
        tmp_path,
        head_for=lambda _repo: None,
    )
    assert rows[0].status == gopins.STATUS_MISSING_SIBLING


def test_apply_syncs_stale_then_tidies_once(tmp_path: Path) -> None:
    rows = gopins.plan(GO_MOD, tmp_path, head_for=fake_head)
    calls: list[list[str]] = []

    def runner(_repo: Path, argv: list[str]) -> bool:
        calls.append(argv)
        return True

    failures = gopins.apply(rows, tmp_path, runner=runner)
    assert failures == []
    gets = [argv for argv in calls if argv[:2] == ["go", "get"]]
    assert gets == [["go", "get", "github.com/cepheuslabs/gcode@" + "f" * 40]]
    assert calls[-1] == ["go", "mod", "tidy"]


def test_apply_skips_tidy_when_nothing_stale(tmp_path: Path) -> None:
    rows = gopins.plan(
        "require github.com/cepheuslabs/apiutil v0.0.0-20260601120000-aaaaaaaaaaaa\n",
        tmp_path,
        head_for=lambda repo: HEADS["apiutil"],
    )
    calls: list[list[str]] = []
    failures = gopins.apply(rows, tmp_path, runner=lambda _r, argv: calls.append(argv) or True)
    assert failures == []
    assert calls == []


def test_apply_reports_get_failure_and_skips_tidy(tmp_path: Path) -> None:
    rows = gopins.plan(GO_MOD, tmp_path, head_for=fake_head)

    def runner(_repo: Path, argv: list[str]) -> bool:
        return argv[:2] != ["go", "get"]

    failures = gopins.apply(rows, tmp_path, runner=runner)
    assert len(failures) == 1
    assert "go get github.com/cepheuslabs/gcode@" in failures[0]
