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
- Build number: `git rev-list --count HEAD`.
- Full version: `YY.M.D+BUILD`.

Override with:

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
```

Store support is deliberately opt-in per product. A disabled store means the
product can build the artifact, but the app listing, package identity, signing
assets, or release policy is not ready yet.

## Repo Adoption

See [docs/adoption.md](docs/adoption.md) for submodule setup and workflow
templates.
