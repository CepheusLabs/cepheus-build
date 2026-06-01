# Native Installers + Code Signing

How Cepheus Build produces distributable, signed desktop installers for the
Flutter products — beyond the raw "open the .app / Release folder" bundles.

Deckhand and Printdeck already modeled this; **Anvil**, **Colorwake Studio**,
and **Deckhand** now share the full set.

## Formats per product

Build the whole set with the `desktop_packages` group:

```bash
./bin/cepheus-build build -p anvil desktop_packages
./bin/cepheus-build build -p colorwake-studio desktop_packages
./bin/cepheus-build build -p deckhand desktop_packages
```

| Product | macOS | Windows | Linux |
|---|---|---|---|
| Anvil | `.dmg` | `.exe` (Inno Setup) | `.deb` · `.rpm` · Flatpak |
| Colorwake Studio | `.dmg` | `.exe` + `.msix` (Store) | `.deb` · `.rpm` · Flatpak |
| Deckhand | `.dmg` | `.exe` (Inno Setup) | `.AppImage` · `.deb` · `.rpm` · Flatpak |

Each format is its own target (`macos-dmg`, `windows-installer`, `linux-deb`,
`linux-rpm`, `linux-flatpak`, …) and each runs only on its native host — the
CLI skips wrong-host targets, and `ci-matrix` routes each to the right runner.

## Where the recipes live (division of labor)

- **cepheus-build (this repo)** owns orchestration: the targets, the
  `desktop_packages` group, global tool declarations in `build.toml`, the
  `ci-matrix` → `setup_*` flags, the reusable CI workflow, the shared signing
  helpers (`scripts/sign-windows.ps1`, `scripts/sign-linux-gpg.sh`), and the
  repo-publish helpers (`scripts/publish-{apt,yum,flatpak}-repo.sh`).
- **Each product repo** owns its packaging recipe under `packaging/<os>/`:
  - macOS DMG: `scripts/package-macos-developerid.sh` (anvil, colorwake) or
    `packaging/macos/build_dmg.sh` (deckhand) — already existed.
  - Windows: `packaging/windows/<app>.iss` + `packaging/windows/build_installer.ps1`.
  - Linux: `packaging/linux/build_deb.sh`, `build_rpm.sh`, `build_flatpak.sh`
    (+ a `<app-id>.yml` Flatpak manifest).

The product `commands` build the app, then call these scripts with
`$CBUILD_VERSION`. The scripts call cepheus-build's shared signers internally.

## Per-host build prerequisites

`doctor` reports what's missing; `install-deps` installs what it can.

- **macOS** — Xcode CLT, CocoaPods, the product's native toolchain (Rust for
  anvil/colorwake, Go for deckhand). `create-dmg` optional (scripts fall back
  to `hdiutil`).
- **Windows** — Flutter, the native toolchain, and **Inno Setup** (`iscc` on
  PATH). CI installs it via `choco install innosetup`.
- **Linux** — Flutter, the native toolchain, plus per-format:
  `dpkg-deb` (deb), `rpmbuild` (rpm), `flatpak` + `flatpak-builder` (flatpak).
  All declared in `build.toml`; CI installs them only for the rows that need
  them (driven by the `setup_deb` / `setup_rpm` / `setup_flatpak` matrix flags).

## Code signing

Signing is **env-gated everywhere**: when the relevant secrets are absent, the
packaging scripts emit an **unsigned** artifact plus a warning and exit 0, so
builds work before signing is set up. Provide the secrets to turn signing on
with **no code change**.

### Windows — Azure Trusted Signing

`scripts/sign-windows.ps1` signs via the cross-platform `sign` dotnet tool.
Set **all** of:

| Variable | Meaning |
|---|---|
| `AZURE_TENANT_ID` / `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` | service-principal auth |
| `TRUSTED_SIGNING_ENDPOINT` | e.g. `https://eus.codesigning.azure.net` |
| `TRUSTED_SIGNING_ACCOUNT` | Trusted Signing account name |
| `TRUSTED_SIGNING_CERT_PROFILE` | certificate profile name |

> **Eligibility**: Trusted Signing public-trust certs require a US/CA/EU/UK
> entity (org path historically wanted 3+ years of history; the individual path
> waives that for US/CA). Confirm Cepheus Labs qualifies before relying on it.

### macOS — Developer ID + notarization

Already implemented in each product's DMG script. Note the two styles:

- **anvil / colorwake** (`scripts/package-macos-developerid.sh`): sign with
  `*_DEVID_IDENTITY` (default: `Developer ID Application: Cepheus Labs, LLC
  (J2W5M4CY69)`), notarize via a **notarytool keychain profile**
  `*_NOTARY_PROFILE` (default `AC_NOTARY`). Set `ANVIL_SKIP_NOTARIZE=1` /
  `COLORWAKE_SKIP_NOTARIZE=1` to sign-only.
  - ⚠️ The keychain profile must be created once per machine
    (`xcrun notarytool store-credentials AC_NOTARY …`). On a fresh CI runner it
    won't exist — either provision it in a setup step, or run with
    `*_SKIP_NOTARIZE=1` until that's wired.
- **deckhand** (`packaging/macos/build_dmg.sh`): env-driven — `MACOS_SIGN_ID`,
  `MACOS_NOTARIZE_APPLE_ID`, `MACOS_NOTARIZE_PASSWORD`, `MACOS_NOTARIZE_TEAM_ID`.
  This is the more CI-friendly shape.

### Linux — GPG

`scripts/sign-linux-gpg.sh` writes a detached `.asc` next to each artifact and
is reused (sourced) to sign repo metadata. Set:

- `GPG_SIGNING_KEY` — armored private key (or base64 of one)
- `GPG_SIGNING_KEY_ID` — optional; key id/fingerprint to sign with
- `GPG_SIGNING_KEY_PASSPHRASE` — optional; for non-interactive signing

### Enabling signing in CI

The reusable workflow declares all of the above as **optional**
`workflow_call` secrets and passes them to the build as env. The caller
(`templates/github/app-build.yml`) forwards them with `secrets: inherit` — so
to turn signing on, just add the secrets in the product repo's Actions
settings. Nothing is ever echoed to logs.

## Distribution

### Direct downloads — GitHub Releases (enabled)

The `github_release` store lane uploads the built installers to the release
tagged `v<version>-<build>`:

```bash
./bin/cepheus-build deploy -p anvil github_release
```

### Package repositories — apt / yum / Flatpak (scaffolded, disabled)

`apt_repo`, `yum_repo`, and `flatpak_repo` lanes wrap the shared
`scripts/publish-*-repo.sh` helpers. They build + GPG-sign repo metadata
locally and upload only when the destination is configured. They are
`enabled = false` until the **repo host is chosen** (see below). Each needs
`GPG_SIGNING_KEY` plus a target:

| Lane | Target var | Local output (when target unset) |
|---|---|---|
| `apt_repo` | `APT_REPO_TARGET` (`user@host:/srv/apt` or `s3://…`) | `packaging/linux/dist/apt/` |
| `yum_repo` | `YUM_REPO_TARGET` | `packaging/linux/dist/yum/` |
| `flatpak_repo` | `FLATPAK_REPO_TARGET` | `packaging/linux/dist/flatpak-repo/` |

To go live: pick a host (GitHub Pages, S3 + CloudFront, or your own server),
set the `*_REPO_TARGET` (and `GPG_SIGNING_KEY`), and flip the lane to
`enabled = true`.

## Open items

- **Azure Trusted Signing** — sign up + confirm entity eligibility, then add
  the six Trusted Signing / Azure secrets. Until then, Windows installers build
  unsigned.
- **Linux repo host** — choose where the apt/yum/flatpak repos live, then
  configure the `*_REPO_TARGET`s and enable the repo lanes.

See [`INSTALLERS.md`](../INSTALLERS.md) at the repo root for the implementation
tracker, and [`stores.md`](stores.md) for store-lane details.
