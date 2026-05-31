# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Cepheus Build is shared build and release orchestration for Cepheus Labs Flutter app products. It handles packaging, versioning, artifact collection, and store-release automation for Flutter apps with product-specific native pieces (Rust, Go, embedded systems). It is intentionally separate from Forge (shared UI design system, vendored as a git submodule at `shared/forge`).

There are two deliverables in this repo: a Python CLI (`cepheus_build/`) that does the actual work, and a Flutter desktop GUI (`app/`) that is a thin front-end shelling out to that CLI.

## Repo Layout Assumption (important)

Product configs in `products/*.toml` set `repo_root = "../../<product>"`, resolved **relative to the `products/` directory**. So the default expectation is that each product repo sits two levels up — i.e. as a *sibling* of this repo (e.g. `~/Developer/git/printdeck` next to `~/Developer/git/cepheus-build`). There is no submodule or checkout of the product repos inside this one; builds operate on those external checkouts.

The other supported layout is vendoring this repo as a submodule at `shared/cepheus-build` inside each app repo and overriding the root with `--repo-root "$PWD"`. Always pass `--repo-root` in CI and from inside an app repo. If `repo_root`/`app_dir` don't exist, `doctor` will report them as missing.

## Common Commands

### CLI (Python, no build step)

Run via `./bin/cepheus-build` (a thin `sys.path` shim into `cepheus_build.cli:main`). No dependencies to install for core commands; only `deploy google_play` needs `google-api-python-client`/`google-auth`.

```bash
./bin/cepheus-build --version                               # Print toolkit version
./bin/cepheus-build list                                    # List known products
./bin/cepheus-build list --json                             # Same, JSON output
./bin/cepheus-build plan -p <product> <targets>             # Preview build plan (no execution)
./bin/cepheus-build plan -p <product> <targets> --json      # Same, JSON output
./bin/cepheus-build stamp -p <product>                      # Print the resolved version stamp
./bin/cepheus-build doctor -p <product> <targets>           # Check paths + tool prerequisites
./bin/cepheus-build doctor -p <product> <targets> --json    # Same, JSON output
./bin/cepheus-build describe --json                         # All products + runner profiles as JSON
./bin/cepheus-build describe -p <product> --json            # Full product description as JSON
./bin/cepheus-build install-deps -p <product> <targets>     # Install configured tools
./bin/cepheus-build build -p <product> <targets>            # Execute local build
./bin/cepheus-build build -p <product> <targets> --install-missing-deps   # Install tools first
./bin/cepheus-build build -p <product> <targets> --execution-mode github  # Dispatch CI instead
./bin/cepheus-build build -p <product> <targets> --no-sync               # Skip pre-build repo sync
./bin/cepheus-build build -p <product> <targets> --require-clean         # Abort if uncommitted changes
./bin/cepheus-build artifacts -p <product> <targets> --copy-to dist/      # Collect outputs
./bin/cepheus-build deploy -p <product> <store_lane>        # Store deployment
./bin/cepheus-build deploy -p <product> <store_lane> --dry-run  # Validate lane; skip real upload
./bin/cepheus-build ci-matrix -p <product> --runner-profile github-hosted <targets> --pretty
./bin/cepheus-build local-sweep <product1> <product2> --targets desktop --dry-run
```

Products: `printdeck`, `colorwake-studio`, `anvil`, `deckhand`, `foundry`. `targets` are individual target names (`macos`, `web`, `android`) or group names defined per product (`desktop`, `all`, `os`, `quality`, etc.). Most subcommands default to the `desktop` group when no target is given (`ci-matrix` defaults to `all`).

A pytest suite + ruff/mypy config live in the repo. Install dev extras and run them: `pip install -e .[dev]`, then `pytest`, `ruff check .`, and `mypy cepheus_build` (mypy is advisory). `tests/` covers the pure logic and a CLI smoke layer; the command handlers (`cmd_build`, `run_target`, `collect_artifacts`, `sync_repo_before_build`) are also tested with a temp product config + monkeypatched `run_command`. Also validate behavior with `plan`/`doctor`/`--dry-run` against a product, e.g. `./bin/cepheus-build build -p printdeck all --dry-run`. The `.github/workflows/ci.yml` job runs these but is **manual-only** (`workflow_dispatch`) to conserve runner minutes.

Global flags available on all subcommands: `--no-color` disables ANSI color output; the `NO_COLOR` environment variable (any non-empty value) has the same effect. `--version` prints the toolkit version and exits. Subprocess auxiliary commands (tool checks, git sync, `gh workflow run` dispatch) have timeouts to prevent hangs.

### GUI App (Flutter/Dart)

```bash
git submodule update --init --recursive   # forge submodule must exist first
cd app
flutter pub get
flutter run -d macos          # Run the desktop build console
flutter analyze               # Lint (uses package:flutter_lints)
flutter test                  # Widget tests (test/widget_test.dart)
```

The app depends on `package:forge` via path (`../shared/forge`); without the submodule, `pub get` fails.

## Architecture

### CLI (`cepheus_build/cli.py`)

Single-file CLI (~1500 lines, argparse). Per-subcommand `cmd_*` functions are wired in `build_parser()`; `main()` calls `augment_process_path()` first, then dispatches. Key concepts:

- **ProductConfig** — wrapper around one product TOML. Exposes `targets`, `groups`, `stores`, `repo_root`, `app_dir`, etc. `expand_targets()` resolves group names → concrete enabled targets; `target()` rejects unknown/`enabled = false` targets.
- **Stamp / `compute_stamp()`** — version is `YY.M.D` (UTC only if `[version].utc`); build number is `git rev-list --count HEAD` **run in the product's `repo_root`** (falls back to `GITHUB_RUN_NUMBER` or `1`). Full form `YY.M.D+BUILD`. Override version with `<PREFIX>_BUILD_NAME` or `CBUILD_VERSION`; build number with `<PREFIX>_BUILD_NUMBER` or `CBUILD_BUILD_NUMBER`. `<PREFIX>` is `[version].env_prefix` or the slug uppercased with `-`→`_`. In a `local-sweep`, each product computes its own build number independently from its repo, so numbers can differ across products in the same sweep.
- **Host detection** — `current_host()` normalizes `darwin→macos`, `win32→windows`. Targets/stores declare `hosts`; `ensure_host()` skips (or errors on) targets whose host doesn't match. Desktop Flutter builds are host-native (Linux needs Linux, etc.).
- **`augment_process_path()`** — prepends `~/.cargo/bin`, `~/.pub-cache/bin`, `~/.local/bin`, Homebrew, and the Docker.app bin dir to `PATH` on every run, so tools installed mid-build (e.g. via `--install-missing-deps`) are found by later targets in the same run.
- **Tool checking** — tools are defined globally in `build.toml` with `hint`, optional `binary`, platform-specific `check` command, and `install` hints. `tool_status()` reports presence; `require_target_tools()` blocks a build on missing tools (unless `--no-check-tools`). `buildroot` is a `VIRTUAL_TOOL` (always "ok"). When `doctor` finds missing tools it prints a hint suggesting `install-deps`.
- **`describe` subcommand** — machine-readable introspection: `describe --json` lists all products and runner profiles; `describe -p <product> --json` emits a full JSON object with slug, display_name, repo_root, app_dir, github config, groups, targets (with hosts/tools/enabled), stores (with enabled/hosts/required_env), target_choices, and runner_profiles. The GUI uses this instead of parsing TOML directly. `list`, `plan`, and `doctor` also accept `--json` for structured output.
- **Build sync controls** — `--no-sync` skips the pre-build `git pull`/submodule update; `--require-clean` aborts if the product working tree has uncommitted changes. Default is sync on, no clean check. `--dry-run` always skips sync regardless of `--no-sync`.

### The `CBUILD_*` environment contract (CLI ↔ product TOML)

This is the primary interface between the CLI and product configs. `build_env()` injects these into every command's environment, and product TOML `commands` reference them heavily (e.g. `make web VERSION="$CBUILD_VERSION"`):

`CBUILD_PRODUCT`, `CBUILD_DISPLAY_NAME`, `CBUILD_TOOL_ROOT` (this repo), `CBUILD_REPO_ROOT` (product repo), `CBUILD_APP_DIR`, `CBUILD_VERSION`, `CBUILD_BUILD_NUMBER`, `CBUILD_FULL_VERSION`, `CBUILD_DRY_RUN` (set to `1` when `--dry-run` is active, including in `deploy`), plus `<PREFIX>_BUILD_NAME` / `<PREFIX>_BUILD_NUMBER`. When editing or adding product targets, use these instead of hardcoding paths/versions.

### Target execution (two modes)

In `run_target()`, a target runs in one of two ways:
1. **Explicit `commands`** (what every current product uses) — the listed shell commands run verbatim in `cwd` (relative to `repo_root`), with `pre`/`post` commands around them.
2. **Flutter fallback** (no `commands`) — auto-runs `flutter pub get` (unless disabled), optional `flutter create`, then a generated `flutter build <flutter|target>` with `--dart-define`s, `--build-name`/`--build-number`, and `flutter_args`.

### Host-mapped config values

`commands`, `tools`, `pre`, `post`, and `env` may be either a list **or** a host-keyed table: `{ linux = [...], macos = [...], windows = [...], default = [...] }`. `host_list()` picks the current host's entry (or `default`). Foundry's OS targets rely on this to run `bash` scripts on Unix and PowerShell on Windows. See `schemas/product.schema.json` (`stringListOrHostMap`).

### Auto-repair / failure detection (`run_command`)

- If a command's output matches CocoaPods specs-staleness patterns, the CLI runs `pod repo update` once and retries the command automatically.
- Some commands exit 0 but actually failed (e.g. `xcodebuild` IPA export). `should_treat_output_as_failure()` scans output for known failure strings and treats them as failures even on exit 0. Add patterns to `COMMAND_OUTPUT_FAILURE_PATTERNS` / `COCOAPODS_SPECS_REPAIR_PATTERNS` as needed.

### Configuration (TOML)

- **`build.toml`** — global: GitHub `runner_profiles` (`github-hosted`, `self-hosted`) and `[tools.*]` definitions.
- **`products/*.toml`** — per product: `[product]` (slug, repo_root, app_dir), `[version]`, `[github]` (repository, workflow), `[groups]`, `[targets.*]`, `[stores.*]`, optional `[flutter]` dart_defines. `schemas/product.schema.json` documents the shape.
- A repo may also carry a private `.cepheus-build.toml` at its root (used when `--config`/`--product` resolves to it). Prefer central configs here.

### GUI App (`app/`)

Flutter desktop console using Forge. `app/lib/main.dart` is the screen; `app/lib/build_models.dart` holds `BuildAction`, `ExecutionMode`, `BuildSettings`, and history models. The GUI **shells out to `bin/cepheus-build`** (on Windows: `python bin/cepheus-build`) and streams stdout/stderr into a filterable log view. It populates dropdowns via `describe --json` and `describe -p <product> --json` (the machine-readable introspection surface) rather than parsing TOML directly. Settings + run history persist to `history/build-history.json`. Foundry is special-cased in the UI (Buildroot options).

### CI (`.github/workflows/app-build.yml`)

Reusable workflow (`workflow_call`, name "Shared App Build"). A `plan` job runs `ci-matrix` to produce one matrix row per host (each row carries `setup_flutter`/`setup_rust`/`setup_go`/`setup_cargo_ndk`/`setup_wasm_pack`/`setup_buildroot` flags derived from the targets' declared tools); `build` jobs install only the needed toolchains, run `build --skip-unsupported`, then `artifacts --copy-to`. `matrix-json` input overrides the generated matrix. `templates/github/app-build.yml` is the thin caller product repos copy in. See `docs/adoption.md`.

GitHub execution mode (`build --execution-mode github`) does **not** run the matrix locally — it runs `gh workflow run <workflow> -R <product-repo>` to dispatch the *product repo's own* caller workflow (default filename `shared-build.yml`, from `[github].default_workflow`), passing targets/profile/mode as inputs.

### Deploy (`cepheus_build/deploy/`)

`deploy` validates a store lane's `required_env` and host, then runs its `commands`. `google_play.py` is a standalone module (invoked by product configs as `python3 -m cepheus_build.deploy.google_play`) that uploads an AAB via service-account auth. Microsoft Store uses `scripts/submit-msstore.ps1`. Stores are opt-in per product (`enabled = false` means the artifact builds but release plumbing isn't ready). See `docs/stores.md`.

`deploy --dry-run` sets `CBUILD_DRY_RUN=1` in the environment before running lane commands, so deploy modules that check this variable (including `google_play.py`) skip real API calls. Use this to validate lane config without triggering a store upload.

## Key Patterns

- Build/store commands run in the **product's** repo (`repo_root`/`cwd`), not this repo.
- Real local builds first auto-sync the product checkout: fast-forward-only `git pull --recurse-submodules` then `submodule update --init --recursive` (`sync_repo_before_build()`). `--dry-run` does not mutate the checkout.
- `--skip-unsupported` (default true) skips wrong-host targets; `--keep-going` (default true) continues past a failed target and prints a summary at the end. `local-sweep` runs whole products one after another with the same flags.
- `history/` holds run logs and a shared `build-history.json` the team commits when useful.

## Requirements

- Python >= 3.11 (uses `tomllib`)
- Flutter SDK (Dart >= 3.11.5) for the GUI app
- Product-specific: Rust/Cargo, Go, Docker (+ running daemon for Foundry OS), Xcode, CocoaPods, etc. — use `doctor` to check.
