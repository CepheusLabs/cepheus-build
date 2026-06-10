# Adoption

## Preferred: Use As A Sibling Checkout

Keep `cepheus-build` beside product repos and invoke it directly:

```bash
../cepheus-build/bin/cepheus-build deps -p printdeck-app --repo-root "$PWD" --write
../cepheus-build/bin/cepheus-build build -p printdeck-app --repo-root "$PWD" all --skip-unsupported
```

`deps --write` creates ignored local override files for first-party packages.
This is the replacement path for recursive first-party submodules; see
[`dependencies.md`](dependencies.md).

## Local Builds

Local builds use the same product configs as CI. They run on the current
machine and skip targets for other operating systems when asked:

```bash
../cepheus-build/bin/cepheus-build plan -p printdeck-app --repo-root "$PWD" all
../cepheus-build/bin/cepheus-build build -p printdeck-app --repo-root "$PWD" all --skip-unsupported
```

Build one target when you are on the right host:

```bash
../cepheus-build/bin/cepheus-build build -p colorwake-studio --repo-root "$PWD" macos
../cepheus-build/bin/cepheus-build build -p anvil --repo-root "$PWD" android
../cepheus-build/bin/cepheus-build build -p deckhand --repo-root "$PWD" windows-installer
```

## GitHub-Hosted Runners

GitHub-hosted runners are opt-in. Add a thin workflow in the app repo and set
both the build profile and planning runner explicitly:

```yaml
name: app-build

on:
  pull_request:
  workflow_dispatch:

jobs:
  build:
    uses: CepheusLabs/cepheus-build/.github/workflows/app-build.yml@main
    with:
      product: printdeck-app
      toolkit-ref: main
      runner-profile: github-hosted
      planner-runner-json: '"ubuntu-latest"'
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

Use `runner-profile: self-hosted`. This is the default for Cepheus Build. The
planning job also needs a runner, so point it at a Linux self-hosted runner:

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
../cepheus-build/bin/cepheus-build build --config .cepheus-build.toml linux
```

Prefer central configs in this repo for shared product behavior. Prefer local
configs only for experiments, forks, or app-private release lanes.
