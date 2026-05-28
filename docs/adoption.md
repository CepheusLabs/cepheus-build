# Adoption

## Add As A Submodule

Use the same path in every app repo:

```bash
git submodule add https://github.com/CepheusLabs/cepheus-build.git shared/cepheus-build
git commit -m "build: add shared Cepheus build toolkit"
```

## Local Builds

Local builds use the same product configs as CI. They run on the current
machine and skip targets for other operating systems when asked:

```bash
shared/cepheus-build/bin/cepheus-build plan -p printdeck --repo-root "$PWD" all
shared/cepheus-build/bin/cepheus-build build -p printdeck --repo-root "$PWD" all --skip-unsupported
```

Build one target when you are on the right host:

```bash
shared/cepheus-build/bin/cepheus-build build -p colorwake-studio --repo-root "$PWD" macos
shared/cepheus-build/bin/cepheus-build build -p anvil --repo-root "$PWD" android
shared/cepheus-build/bin/cepheus-build build -p deckhand --repo-root "$PWD" windows-installer
```

## GitHub-Hosted Runners

Add a thin workflow in the app repo:

```yaml
name: app-build

on:
  pull_request:
  workflow_dispatch:

jobs:
  build:
    uses: CepheusLabs/cepheus-build/.github/workflows/app-build.yml@main
    with:
      product: printdeck
      toolkit-ref: main
      runner-profile: github-hosted
      targets: all
```

The shared workflow generates this kind of matrix automatically:

```json
{
  "include": [
    {"name": "linux", "runner": "ubuntu-latest", "targets": "web android linux"},
    {"name": "macos", "runner": "macos-latest", "targets": "ios macos"},
    {"name": "windows", "runner": "windows-latest", "targets": "windows"}
  ]
}
```

## Self-Hosted GitHub Runners

Use `runner-profile: self-hosted`. The planning job also needs a runner, so
point it at a Linux self-hosted runner if the org should avoid
GitHub-provided minutes entirely:

```yaml
jobs:
  build:
    uses: CepheusLabs/cepheus-build/.github/workflows/app-build.yml@main
    with:
      product: deckhand
      runner-profile: self-hosted
      planner-runner-json: '["self-hosted","linux"]'
      targets: desktop_packages
```

If the self-hosted images already contain Flutter, Rust, and Go, disable the
setup actions:

```yaml
jobs:
  build:
    uses: CepheusLabs/cepheus-build/.github/workflows/app-build.yml@main
    with:
      product: deckhand
      runner-profile: self-hosted
      planner-runner-json: '["self-hosted","linux"]'
      targets: desktop_packages
      setup-flutter: false
      setup-rust: false
      setup-go: false
```

The generated rows use these labels by default:

```json
{
  "include": [
    {"name": "linux", "runner": ["self-hosted", "linux"], "targets": "linux-appimage"},
    {"name": "macos", "runner": ["self-hosted", "macos"], "targets": "macos-dmg"},
    {"name": "windows", "runner": ["self-hosted", "windows"], "targets": "windows-installer"}
  ]
}
```

Rows also carry setup hints such as `setup_flutter`, `setup_rust`, and
`setup_go`. The workflow uses those hints to install only the toolchains needed
by that row. Foundry OS rows also carry `setup_buildroot`, which installs the
Linux packages Buildroot needs on GitHub-hosted runners.

For pre-baked Foundry self-hosted runners, disable that extra package install
and point the build at your prepared Buildroot checkout:

```yaml
jobs:
  build:
    uses: CepheusLabs/cepheus-build/.github/workflows/app-build.yml@main
    with:
      product: foundry
      runner-profile: self-hosted
      planner-runner-json: '["self-hosted","linux"]'
      targets: os
      setup-buildroot-deps: false
      buildroot-dir: /opt/buildroot
```

## Custom Matrices

When a product needs a special runner label, GPU builder, notarization host, or
temporary split, pass `matrix-json`. It overrides `runner-profile`:

```yaml
jobs:
  build:
    uses: CepheusLabs/cepheus-build/.github/workflows/app-build.yml@main
    with:
      product: anvil
      matrix-json: >-
        {
          "include": [
            {"name":"linux-gpu","runner":["self-hosted","linux","gpu"],"targets":"linux"},
            {"name":"macos-sign","runner":["self-hosted","macos","codesign"],"targets":"ios macos"}
          ]
        }
```

## Local Product Config

If a repo needs private build details, place this at `.cepheus-build.toml`:

```toml
[product]
slug = "my-app"
display_name = "My App"
repo_root = "."
app_dir = "app"

[targets.linux]
hosts = ["linux"]
flutter = "linux"
artifacts = ["app/build/linux/x64/release/bundle"]
```

Then call:

```bash
shared/cepheus-build/bin/cepheus-build build --config .cepheus-build.toml linux
```

Prefer central configs in this repo for shared product behavior. Prefer local
configs only for experiments, forks, or app-private release lanes.
