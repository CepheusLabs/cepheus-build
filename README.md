# Cepheus Build

Shared build and release orchestration for Cepheus Labs app products.

This repo is intentionally separate from `forge`. Forge is shared UI. Cepheus
Build is shared packaging, versioning, artifact collection, and store-release
glue for Flutter apps with product-specific native pieces.

## Products

The first supported product configs are:

- `colorwake-studio` - Flutter app plus Rust native library.
- `printdeck` - Flutter app plus existing desktop/mobile store packaging.
- `anvil` - Flutter app plus Rust slicer/FFI workspace.
- `deckhand` - Flutter desktop app plus Go sidecar/helper packaging.
- `foundry` - Rust host tools, embedded MCU firmware, and Buildroot-based
  printer OS images staged for Deckhand.

## Quick Start

From a checkout beside the app repos:

```bash
./bin/cepheus-build --version
./bin/cepheus-build list
./bin/cepheus-build plan -p printdeck all
./bin/cepheus-build doctor -p anvil desktop
./bin/cepheus-build build -p colorwake-studio macos --install-missing-deps
./bin/cepheus-build artifacts -p deckhand desktop_packages --copy-to dist/deckhand
./bin/cepheus-build plan -p foundry os
./bin/cepheus-build local-sweep printdeck deckhand --targets desktop --dry-run
```

## GUI

The lightweight desktop console lives in `app/` and uses Forge for UI:

```bash
cd app
flutter run -d macos
```

It can run local builds directly or dispatch GitHub workflows with runner
profiles loaded from `build.toml`. Product repositories and workflow names come
from each `products/*.toml` file. Local run history is stored in
`history/build-history.json` so the team can commit it when useful. The console
also reads `[stores.*]` lanes from product configs for deploy preview and
store submission runs. Local Build runs automatically install configured
missing tools before starting the build; Dry Run keeps to preview output only.
The local build environment includes common user tool directories such as
`~/.cargo/bin`, so tools installed during dependency setup are available to
later targets in the same run.
Real local builds also update the product checkout first with a normal
fast-forward-only `git pull` and recursive submodule update. Dry Run does not
mutate the checkout.
Foundry OS Docker targets need a running Docker-compatible engine. Docker
Desktop is not required if `docker info` works through Docker Engine, Colima,
OrbStack, Rancher Desktop, or another compatible daemon.

From inside an app repo that vendors this as `shared/cepheus-build`:

```bash
shared/cepheus-build/bin/cepheus-build build \
  --product printdeck \
  --repo-root "$PWD" \
  desktop
```

## Build Modes

Use `release` for store/distribution builds. Use `profile` when you need a
near-release build with profiling hooks for performance work; it is not the
normal store-submission mode.

Cepheus Build supports the same product configs in three places:

- Local builds: run `shared/cepheus-build/bin/cepheus-build build ...` from a
  developer machine or release workstation. Desktop Flutter builds are
  host-native: Linux desktop targets need Linux, Windows targets need Windows,
  and Apple targets need macOS.
- GitHub-hosted runners: use the reusable workflow with the
  `github-hosted` runner profile from `build.toml`.
- Self-hosted GitHub runners: use the reusable workflow with the `self-hosted`
  runner profile from `build.toml`; those labels are org-level by default.

You can inspect the generated CI matrix without running a build:

```bash
./bin/cepheus-build ci-matrix -p printdeck --runner-profile github-hosted all --pretty
./bin/cepheus-build ci-matrix -p deckhand --runner-profile self-hosted desktop_packages --pretty
```

Generated matrix rows include setup hints for Flutter, Rust, Go, `cargo-ndk`,
`wasm-pack`, and Buildroot dependencies. The reusable workflow installs those
on GitHub-hosted runners by default; self-hosted workflows can disable setup
when runner images already include the toolchains.

`ipadOS` ships through the `ios` lane. Flutter/Xcode produces the universal
iOS app; product entitlements and App Store settings decide iPhone/iPad
availability.

## Versioning

Every build receives the same stamp:

- Version: `YY.M.D`, UTC only if a product config opts in.
- Build number: `git rev-list --count HEAD` run inside the **product's own
  `repo_root`**, not this repo.
- Full version: `YY.M.D+BUILD`.

In a `local-sweep`, the build number is computed independently for each
product from that product's repo, so build numbers can differ across products
in the same sweep run. To force a shared stamp across products, set the
override variables explicitly:

```bash
CBUILD_VERSION=26.5.28 CBUILD_BUILD_NUMBER=1234 ./bin/cepheus-build build -p printdeck web
```

Product-prefixed variables also work, for example
`PRINTDECK_BUILD_NAME` and `PRINTDECK_BUILD_NUMBER`.

## Store Deploys

Deploy lanes are declared under `[stores.*]` in each product config. The shared
CLI validates required environment variables, host OS, and then runs the
configured commands:

```bash
./bin/cepheus-build deploy -p printdeck google_play
./bin/cepheus-build deploy -p colorwake-studio testflight_ios
./bin/cepheus-build deploy -p deckhand msstore --dry-run
```

`--dry-run` on `deploy` does not upload to the store. The CLI sets the
`CBUILD_DRY_RUN=1` environment variable so that deploy modules (such as the
Google Play uploader) also skip real API calls. This is the safe way to verify
lane config before a real release.

Store support is deliberately opt-in per product. A disabled store means the
product can build the artifact, but the app listing, package identity, signing
assets, or release policy is not ready yet.

## Introspection

Use `describe` to get machine-readable JSON about products and runner profiles:

```bash
# All products and runner profiles
./bin/cepheus-build describe --json

# Full description of one product (slug, targets, stores, groups, github config)
./bin/cepheus-build describe -p printdeck --json
```

The `describe -p <product> --json` output includes target host restrictions,
required tools, enabled/disabled state, store lanes with `required_env`, and
the full list of `target_choices`. The GUI uses this endpoint instead of
parsing TOML directly.

`list`, `plan`, and `doctor` also accept `--json` to emit structured output
instead of human-readable text:

```bash
./bin/cepheus-build list --json
./bin/cepheus-build plan -p anvil desktop --json
./bin/cepheus-build doctor -p deckhand desktop --json
```

When `doctor` finds missing tools it prints a suggestion to run `install-deps`.

## Global Flags

| Flag | Description |
|------|-------------|
| `--version` | Print the toolkit version and exit. |
| `--no-color` | Disable ANSI color in all output. Also honored via the `NO_COLOR` environment variable (any non-empty value). |

## Build Sync Controls

By default, a local `build` fast-forwards the product repo before running
targets (`git pull --recurse-submodules` + `submodule update --init
--recursive`). Two flags control this:

```bash
# Skip the pre-build sync (use the checkout as-is)
./bin/cepheus-build build -p printdeck macos --no-sync

# Abort if the product working tree has uncommitted changes
./bin/cepheus-build build -p printdeck macos --require-clean
```

`--dry-run` never mutates the product checkout regardless of `--no-sync`.

## Security / Trust Boundary

Product TOML `commands`, `pre`, `post`, and store lane entries are executed via
the shell with full environment interpolation. They are **trusted input**.

- Do not run `cepheus-build` with a `--config`/`.cepheus-build.toml` from an
  untrusted repository without reviewing its contents — a malicious config can
  execute arbitrary shell commands.
- Store-lane `required_env` values must reference **file paths** to credential
  files, not inlined secret content. For example, `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`
  should point to a JSON key file on disk.
- `history/build-history.json` records command lines from past runs. Use
  env-var references in lane commands (e.g. `$MY_SECRET`) rather than literal
  values so secrets are not stored in history.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup.

## Repo Adoption

See [docs/adoption.md](docs/adoption.md) for submodule setup and workflow
templates.
