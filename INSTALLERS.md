# Cepheus Build — Native Installers + Code Signing

Tracker for adding OS-native installers and code signing for **Anvil**,
**Colorwake Studio**, and **Deckhand**, extending the pattern Deckhand and
Printdeck already model.

All cepheus-build work happens on `main` in the working tree, committed
incrementally. **Product-repo work (packaging scripts in anvil / colorwake /
deckhand) is left UNCOMMITTED in those trees** — they are currently dirty
and/or on feature branches, so we never commit or switch branches there.

Status key: `[ ]` pending · `[~]` partial/blocked · `[x]` done & verified

---

## Decisions (locked with Evan, 2026-05-31)

| Dimension | Choice |
|---|---|
| Windows format | `.exe` installer (Inno Setup) |
| Windows signing | **Azure Trusted Signing** — env-gated; build now, flip on later |
| Linux formats | `.deb` + `.rpm` + Flatpak (keep Deckhand's existing AppImage too) |
| Linux distribution | Both: loose files on GitHub Releases **and** self-hosted GPG-signed apt/yum repos |
| Flatpak distribution | Self-hosted GPG-signed OSTree Flatpak repo |
| macOS format | `.dmg` (Developer ID + notarized) |

**Azure is not signed up yet.** Everything is wired so that when the Trusted
Signing secrets exist, signing turns on automatically; until then the build
produces an unsigned installer with a warning (same env-gated pattern as
Deckhand's macOS DMG today).

### Signing env contract (set these later to enable signing)

- **Windows (Azure Trusted Signing)** — `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`,
  `AZURE_CLIENT_SECRET`, `TRUSTED_SIGNING_ENDPOINT`, `TRUSTED_SIGNING_ACCOUNT`,
  `TRUSTED_SIGNING_CERT_PROFILE`. If any unset → unsigned `.exe` + warning.
- **macOS (Developer ID + notarytool)** — already implemented per product:
  - anvil/colorwake: `*_DEVID_IDENTITY`, `*_NOTARY_PROFILE`, `*_SKIP_NOTARIZE`
  - deckhand: `MACOS_SIGN_ID`, `MACOS_NOTARIZE_APPLE_ID/PASSWORD/TEAM_ID`
- **Linux (GPG)** — `GPG_SIGNING_KEY`, `GPG_SIGNING_KEY_ID`,
  `GPG_SIGNING_KEY_PASSPHRASE` for `.deb`/`.rpm`/Flatpak + repo metadata.
  If unset → unsigned packages + warning.

---

## Division of labor

- **cepheus-build owns orchestration**: package targets, `desktop_packages`
  groups, global tool declarations, artifact globs, release + repo-publish
  store lanes, the `ci-matrix` → `setup_*` flag derivation, the reusable CI
  workflow steps, and shared signing helper scripts (`scripts/sign-windows.ps1`,
  `scripts/sign-linux-gpg.sh`).
- **Each product repo owns its packaging recipe**: `packaging/{macos,windows,linux}/`
  scripts. macOS DMG already exists for all three; Windows `.exe` and Linux
  deb/rpm/flatpak are the new scripts to add per repo.

## Product identity constants (verified from each repo)

| Product | app_dir | binary | app id | DMG script (exists) |
|---|---|---|---|---|
| Anvil | `app` | `anvil` | `com.cepheuslabs.anvil` | `scripts/package-macos-developerid.sh` |
| Colorwake Studio | `apps/colorwake_studio` | `colorwake_studio` | `com.cepheuslabs.colorwakestudio` | `scripts/package-macos-developerid.sh` |
| Deckhand | `app` | `deckhand` | `labs.cepheus.deckhand` | `packaging/macos/build_dmg.sh` |

Publisher: **Cepheus Labs, LLC** · Apple Team ID **J2W5M4CY69**.

---

## Checklist

### Wave A — cepheus-build core (orchestrator-owned; commit to main incrementally)
- [ ] **A1. `build.toml` global tools** — add `dpkg-deb`, `rpmbuild`, `flatpak`,
  `flatpak-builder`, `azuresigntool`/Trusted Signing client, `gpg`. (iscc,
  create-dmg, appimagetool already present.)
- [ ] **A2. `github.py` `build_ci_matrix`** — derive new `setup_*` flags from
  the packaging tools so CI installs only what a row needs
  (`setup_deb`, `setup_rpm`, `setup_flatpak`, `setup_innosetup`,
  `setup_win_signing`). One real code change.
- [ ] **A3. `tests/test_github.py`** — cover the new setup-flag derivation +
  re-assert the 3 product configs still produce a valid matrix.
- [ ] **A4. shared signing helpers** — `scripts/sign-windows.ps1` (Azure Trusted
  Signing, env-gated no-op) and `scripts/sign-linux-gpg.sh` (env-gated).

### Wave B — product config TOML (orchestrator-owned; commit to main)
- [ ] **B1. `products/anvil.toml`** — `desktop_packages` group +
  `macos-dmg`, `windows-installer`, `linux-deb`, `linux-rpm`, `linux-flatpak`
  targets; `github_release` lane; apt/yum/flatpak repo-publish lanes.
- [ ] **B2. `products/colorwake-studio.toml`** — same set; keep `windows-msix`,
  add `windows-installer` (.exe). Release + repo lanes.
- [ ] **B3. `products/deckhand.toml`** — add `linux-deb`, `linux-rpm`,
  `linux-flatpak` (keep macos-dmg / windows-installer / linux-appimage);
  add repo-publish lanes (already has `github_release`).

### Wave C — reusable CI workflow (orchestrator-owned; commit to main)
- [ ] **C1. `.github/workflows/app-build.yml`** — install steps for the new
  packaging toolchains gated on the new matrix flags; pass signing secrets
  through as env (never echoed). Do NOT add push/PR triggers.
- [ ] **C2. `templates/github/app-build.yml`** — surface any new inputs the
  caller needs.

### Wave D — product packaging scripts (delegated per repo; LEFT UNCOMMITTED)
- [ ] **D1. Anvil** — `packaging/windows/anvil.iss`,
  `packaging/linux/build_deb.sh`, `build_rpm.sh`, `build_flatpak.sh`
  (+ flatpak manifest). Wire `macos-dmg` to the existing dev-id script.
- [ ] **D2. Colorwake** — same set under `packaging/`; reuse existing dev-id
  DMG script; fix Linux app-id if still placeholder.
- [ ] **D3. Deckhand** — `packaging/linux/build_deb.sh`, `build_rpm.sh`,
  `build_flatpak.sh` (embedding the Go sidecar + helper like its AppImage does).

### Wave E — docs + verification (orchestrator-owned; commit to main)
- [ ] **E1. `docs/installers.md`** — formats, per-OS prereqs, signing env,
  repo hosting, how to enable Azure later. Update `docs/stores.md`.
- [ ] **E2. Final verification** — `.venv/bin/pytest -q` green;
  `ruff check .`; `validate`/`plan`/`describe --json`/`ci-matrix` for all
  three products diffed against the pre-change baseline (GUI parses this).

---

## Open (non-blocking) items
- **Azure entity eligibility** — Trusted Signing public-trust org certs need a
  US/CA/EU/UK entity; org path historically wanted 3 yrs of history (individual
  path now waives that for US/CA). Confirm Cepheus Labs qualifies before flipping
  signing on. Does not block scaffolding.
- **Linux repo host** — where the apt/yum/flatpak repos live (GitHub Pages, S3,
  or own server). Needed before the repo-publish lanes are real; not needed to
  build packages.

## Verification baseline (pre-change)
- `.venv/bin/pytest -q` → **158 passed**.
- `validate` → ok for anvil, colorwake-studio, deckhand.
- Baselines captured at `/tmp/cb_baseline_describe.json`,
  `/tmp/cb_baseline_plan_<product>.json`.
