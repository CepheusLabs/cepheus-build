# Adoption

## Add As A Submodule

Use the same path in every app repo:

```bash
git submodule add https://github.com/CepheusLabs/cepheus-build.git shared/cepheus-build
git commit -m "build: add shared Cepheus build toolkit"
```

Then add a thin workflow in the app repo:

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
```

For self-hosted runners, pass a matrix with runner labels:

```yaml
jobs:
  build:
    uses: CepheusLabs/cepheus-build/.github/workflows/app-build.yml@main
    with:
      product: deckhand
      matrix-json: >-
        [
          {"name":"linux","runner":["self-hosted","linux"],"targets":"linux linux-appimage"},
          {"name":"macos","runner":["self-hosted","macos"],"targets":"macos macos-dmg"},
          {"name":"windows","runner":["self-hosted","windows"],"targets":"windows windows-installer"}
        ]
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

