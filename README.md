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

## Quick Start

From a checkout beside the app repos:

```bash
./bin/cepheus-build list
./bin/cepheus-build plan -p printdeck all
./bin/cepheus-build doctor -p anvil desktop
./bin/cepheus-build build -p colorwake-studio macos
./bin/cepheus-build artifacts -p deckhand desktop_packages --copy-to dist/deckhand
```

From inside an app repo that vendors this as `shared/cepheus-build`:

```bash
shared/cepheus-build/bin/cepheus-build build \
  --product printdeck \
  --repo-root "$PWD" \
  desktop
```

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

