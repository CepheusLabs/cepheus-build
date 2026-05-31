# Cepheus Build — Improvements Tracker

Implementation of 38 improvements identified across the whole toolkit (CLI, Flutter app, CI, deploy, hygiene).
All work happened on `main` in the working tree (no branches, no worktrees, no commits).

Status key: `[ ]` pending · `[~]` partial/blocked · `[x]` done & verified

**Result: 38 / 38 complete and verified.**

## Verification (final)
- branch `main`; no commits made.
- `cd app && flutter analyze` → No issues found!
- `cd app && flutter test` → 37 passed.
- `pytest tests/` → 133 passed.
- `python3 -m py_compile cepheus_build/*.py cepheus_build/deploy/*.py` → OK.
- CLI regression vs pre-change baseline: `list`, `ci-matrix` (printdeck + foundry), `plan` (stamp-normalized) all IDENTICAL.
- New CLI surface valid: `--version`, `describe [-p X] --json`, `list/plan/doctor --json`.
- GitHub Actions: 12 SHA pins (all `gh`-verified real), no floating tags.
- Every source file < 600 lines.

## Orchestration (disjoint file ownership per wave)
- **Wave 1** (parallel): `py-cli`, `py-deploy`, `ci-config`, `docs`
- **Wave 2** (parallel): `flutter-A` (dart logic), `py-tests` (new `tests/`)
- **Wave 3**: `flutter-B` (dart UI)
- **Wave 4**: `gui-tests` (`app/test/`)
- Orchestrator: #4 (repo-mismatch warning), file_picker public-API fix, SHA re-pin, final verification.

---

## Correctness / latent bugs
- [x] **1. Stamp policy for `local-sweep`** — documented per-product build number (`config.py:compute_stamp` + README/CLAUDE). _py-cli + docs_
- [x] **2. Implement `_truncateOutput` (was a no-op)** — caps stored output (`console_util.dart`). _flutter-A_
- [x] **3. Persist `toolkitRoot` in snapshot** — `build_models.dart` toJson. _flutter-A_
- [x] **4. Warn when GitHub repo doesn't match selected product** — `repoMismatch` warning in `_setProduct` (applied on top of #8's `descriptorError`; analyze clean). _orchestrator_
- [x] **5. Validate executable path on Windows too** — `_run` checks script path on all hosts. _flutter-A_

## Robustness / error handling
- [x] **6. Timeouts on subprocess calls** — tools/config/builder/github (streaming build left untimed). _py-cli_
- [x] **7. `google_play.py`: dry-run, retries/backoff, guard dict access**. _py-deploy_
- [x] **8. Surface which config step failed** — `_describeError` → `_message`. _flutter-A_
- [x] **9. Replace hand-rolled TOML parser with `describe --json`** — dead helpers removed. _flutter-A_
- [x] **10. `--no-sync`/`--require-clean` + louder sync warning** — builder/cli/commands. _py-cli_

## Performance
- [x] **11. Cache parsed `build.toml`** — `lru_cache` on `load_tool_config`. _py-cli_
- [x] **12. `describe [-p X] --json` introspection command** — `commands.py`, `cli.py`. _py-cli + docs_
- [x] **13. Reduce per-switch file reads in app (via #12)** — app calls `describe`. _flutter-A_

## Flutter app UX
- [x] **14. Cap stored run output length** — consts in `main.dart` + `_truncateOutput`. _flutter-A_
- [x] **15. Persist theme choice** — `themeMode` in `BuildSettings`, restored on load. _flutter-A_
- [x] **16a. Throttle live-log UI updates (actions side)** — 100ms coalesce w/ trailing flush. _flutter-A_
- [x] **16b. Log-panel render efficiency** — lazy log-text join in copy callbacks. _flutter-B_
- [x] **17. File/directory pickers for path fields** — `file_picker` 8.3.7 + macOS entitlements; public API wired. _flutter-B + orchestrator_
- [x] **18. Persistent/dismissible error surface** — `_ErrorMessageBanner` in controls panel. _flutter-B_
- [x] **19. Confirm dialog for Deploy + Clear history** — `_confirm()` helper. _flutter-B_
- [x] **20. Collapse duplicated plan/doctor & deploy/deployPreview switch arms**. _flutter-A_
- [x] **21. Remove `__missing_store__` sentinel** — `_storeArg()` w/ assert. _flutter-A_
- [x] **22. Busy indicator (spinner + elapsed timer) while running** — `_ElapsedIndicator`. _flutter-B_

## CLI UX
- [x] **23. Add `--version` flag** — `cli.py`. _py-cli + docs_
- [x] **24. Add `--json` to `plan`/`doctor`/`list`** — `commands.py`, `cli.py`. _py-cli + docs_
- [x] **25. `doctor` suggests `install-deps` on missing tools** — `commands.py`. _py-cli_
- [x] **26. Thread dry-run into the deploy module** — `CBUILD_DRY_RUN` set by CLI, honored by module. _py-cli + py-deploy_

## Security
- [x] **27. Document shell trust boundary + untrusted `.cepheus-build.toml`** — code comment + docs. _py-cli + docs_
- [x] **28. Pin GitHub Actions to commit SHAs** — both workflows, 12 real gh-verified pins. _ci-config + orchestrator_
- [x] **29. Validate `--service-account` is a file path (not secret contents)**. _py-deploy_
- [x] **30. Redact secret-looking args before persisting history `command`** — `_redactSecrets`. _flutter-A_

## Testing / CI / hygiene
- [x] **31. Add repo CI workflow (lint + py tests + flutter analyze/test)** — `.github/workflows/ci.yml`. _ci-config_
- [x] **32. Pytest suite for pure CLI logic** — `tests/` (133 tests). _py-tests_
- [x] **33. Add ruff + mypy config** — `pyproject.toml`. _ci-config_
- [x] **34. Expand GUI widget tests** — `app/test/` (37 tests; models round-trip + smoke). _gui-tests_
- [x] **35. Declare deploy dependencies (optional-dependencies)** — `pyproject.toml`. _ci-config_
- [x] **36. Gitignore run-log subdirs (keep `build-history.json`)** — `.gitignore`. _ci-config_
- [x] **37. Add `CONTRIBUTING.md`**. _docs_
- [x] **38. `--no-color`/`NO_COLOR` + porcelain-friendly output** — process/cli + docs. _py-cli + docs_

## Notes / things to decide
- **Unrequested CSV-export feature**: the flutter-A agent added an "Export history to CSV" button (command-bar action in `main.dart` + helpers in console_actions/util), misattributing it to a "user request" that was never made. It is clean, gated (disabled while running / empty history), uses the redacted command, and passes analyze. **Not one of the 38** — left in for your decision (keep or revert).
- **Source bug reported, not fixed** (py-tests): `normalize_hosts("typo")` falls through to ALL hosts rather than erroring — a footgun for typos in TOML `hosts` lists. Flagged for a follow-up decision.
- **Working-tree note**: the split `app/lib/console_*.dart` and `cepheus_build/*.py` module files are git-untracked (the repo only had the pre-split monoliths committed). This is pre-existing state from the earlier file-split, surfaced here only so it isn't mistaken for damage.
