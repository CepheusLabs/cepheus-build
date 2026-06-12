# Release Pipeline — Cepheus Labs Ecosystem

- **Status:** PLANNED (this document)
- **Date:** 2026-06-11
- **Owner repo:** `cepheus-build` (D:\git\CepheusLabs\cepheus-build)
- **Scope:** tag-triggered builds -> signing -> store submission -> public download site + CDN + auto-update feed, for all 7 products

---

## 1. Goal and non-goals

### Goal

A tag push on any product repo produces, with zero manual steps beyond the tag:

1. A GitHub Release (internal archival mirror) with all platform artifacts.
2. Signed artifacts on every platform where signing credentials exist (Windows Authenticode via Azure Trusted Signing, macOS Developer ID + notarization, Linux GPG, Ed25519 update signatures).
3. Store submissions: Google Play (AAB), Microsoft Store (MSIX), Mac App Store (pkg), TestFlight.
4. Public Linux distribution: apt repo, yum repo, self-hosted flatpak repo, AppImage — all on Cloudflare R2 behind `packages.printdeck.app`.
5. Auto-update publication: artifacts + `.sig` to R2 at `cdn.printdeck.app/{product}/{channel}/{version}/{file}`, release record POSTed to the live pd-updates control plane (`https://printdeck.app/api/v1/updates/admin/releases`), registered `paused=true, rollout_pct=0` for staged rollout.
6. A public download site at `downloads.printdeck.app` (static, R2-hosted, CDN-fronted) showing latest versions per product/channel, driven by pd-updates' public endpoints.

Reuse-first: the signing/publish/submit script library in `cepheus-build/scripts/` and the `[stores.*]` lane system already exist and work. This plan **wires triggers, runners, secrets, and one new reusable workflow around them** — it does not rewrite them.

### Non-goals

- **cl_updater client package** (in-app update UX, Sparkle/WinSparkle integration, the WinSparkle 0.8.1 EdDSA upgrade). The supply side (feed, signatures, CDN) is in scope; the consuming client is a separate workstream. Until it ships, the feed is verified by `curl` + `verify-update-eddsa.sh`, not by an app.
- **Flathub** — off the table under its AI-generated-content ban (confirmed 2026-06-11). We self-host a flatpak OSTree repo instead; identical user UX via one `flatpak remote-add`.
- **Snap Store** — deferred; low payoff for a small ISV already shipping AppImage + apt/yum + self-hosted flatpak.
- **Kubernetes / Actions Runner Controller autoscaling** — one host + two VMs serving 8 private repos does not need it. Revisit when the k3s scale-out stack lands.
- **Back-compat / legacy paths** — no production consumers exist; bespoke per-product release workflows (deckhand's 28 KB `release.yml`, printdeck-app's 9 `frontend-*` workflows) are **replaced**, not preserved.
- **Reviving the watchtower webhook deploy** (`deploy.printdeck.app` -> watchtower vhost is dangling); backend deploy stays `printdeck-server-compose.sh`.
- **Semver** — CalVer stays (see locked decision 2).

---

## 2. Locked decisions

These are settled. Do not relitigate (per the design-around-locked-choices directive).

| # | Decision | Source |
|---|----------|--------|
| L1 | **CI/releases run on GitHub Actions self-hosted runners** (errai Linux + dockur VM Windows/macOS agents); **interactive builds use `--execution-mode container`**. The two backends share toolchain images but are separate dispatch paths. | Team decision, pre-existing |
| L2 | **Cloudflare R2 is the single public origin for all release bytes.** One bucket; custom domains `cdn.printdeck.app` (installers/sigs/zsync/apk, immutable `{product}/{channel}/{version}/{file}` layout), `packages.printdeck.app` (apt/yum/flatpak static trees via the publishers' existing `s3://` upload path), `downloads.printdeck.app` (static download site). This **also resolves the open "Linux repo host" item**: `APT_REPO_TARGET`/`YUM_REPO_TARGET`/`FLATPAK_REPO_TARGET` = `s3://$R2_BUCKET/{apt,yum,flatpak}`. errai serves only dynamic surfaces. GitHub Releases stay as internal archival mirror, never linked publicly (repos are private; assets are not publicly downloadable by design). | Judge panel Q1; reaffirms locked decision of 2026-06-06 in `docs/auto-update.md` |
| L3 | **Update feeds stay dynamic on pd-updates** (already deployed in the errai compose stack behind Caddy at `https://printdeck.app/api/v1/updates`): appcasts and `/check` render server-side with rollout/min-version gating and must not become static R2 files. Orange-cloud `printdeck.app` for edge caching of the small XML/JSON responses. | Judge panel Q1 |
| L4 | **Per-product tag-triggered release workflows, logic centralized in a new reusable workflow** `cepheus-build/.github/workflows/app-release.yml` (workflow_call) that wraps the existing `app-build.yml`. Each product repo gets a ~20-line `release.yml` caller (`on: push: tags: ['v*']`, `secrets: inherit`). No central fan-out repo; no scheduled-CLI releases. | Judge panel Q2 |
| L5 | **A release = an annotated git tag `v<YY.M.D>-<count>`** (CalVer, e.g. `v26.6.11-482`) — exactly the string every `github_release` lane already targets. **The tag is authoritative**: the workflow parses it and exports `CBUILD_VERSION`/`CBUILD_BUILD_NUMBER` (and `<PREFIX>_*`) so re-runs are reproducible; `compute_stamp` is only used at tag-creation time. Channel derivation: `v*` -> `stable`, `beta-v*` -> `beta`, scheduled caller -> `nightly`. New CLI command `cepheus-build release -p <product> [--channel beta]` creates and pushes the tag. | Judge panel Q2 |
| L6 | **Runner topology:** org-scoped registration, single Default runner group (extra groups need the Team plan — skip). **Linux = ephemeral auto-re-registering runner containers on errai**, image built FROM the proven `cepheus-build-linux` toolchain image (vendored first-party entrypoint, docker socket mounted, named cache volumes, `--scale github-runner=2`); retire the repo-scoped printdeck-server runner. **Windows/macOS = persistent service-installed runners in the dockur VMs** (`config.cmd --runasservice`; `svc.sh` LaunchAgent + auto-login on macOS — the keychain/notary state requires it). Labels exactly `[self-hosted, linux|windows|macos]` per `build.toml [github.runner_profiles.self-hosted]`; delete the bespoke `macbook-pro` and `printdeck` label requirements. Runner auto-update ON. macOS moves to real Apple hardware (Mac mini) before GA (EULA). | Judge panel Q3 |
| L7 | Workflow rules: **no PRs** (push to main; branch protection bypass is expected), **conventional commits**, **build proper not minimal**, **no back-compat layers** (no production consumers). | Standing directives |
| L8 | Microsoft Store track = **MSIX** (Store signs it; no Authenticode cert required for Store-only distribution). Azure Trusted Signing is needed only for the direct-download `.exe` channel + Windows auto-update GA (SmartScreen). | Evidence digest + store facts |

---

## 3. Architecture overview

```
 DEVELOPER                                  cepheus-build repo (logic lives here)
 ---------                                  ------------------------------------
 cepheus-build release -p deckhand
   |  (compute_stamp -> annotated tag
   |   v26.6.11-482 -> git push)
   v
 PRODUCT REPO  (deckhand-app, anvil, ...)
   .github/workflows/release.yml            <- thin caller, ~20 lines
   on: push: tags ['v*','beta-v*']             uses: CepheusLabs/cepheus-build/
   permissions: contents: write                .github/workflows/app-release.yml@main
   secrets: inherit                            (NEW, workflow_call)
   |
   v
 +---------------------------- app-release.yml ---------------------------------+
 | 1. prepare   [self-hosted,linux]  parse tag -> CBUILD_VERSION/BUILD_NUMBER/  |
 |              CHANNEL; preflight: `cepheus-build deploy --validate` for every |
 |              enabled lane (fail fast on missing secrets)                     |
 | 2. release   `gh release create v$VER-$NUM --verify-tag` (the missing step)  |
 | 3. build     nested call -> EXISTING app-build.yml (ci-matrix plan ->        |
 |              per-OS build+sign matrix -> upload-artifact)                    |
 |    runners:  [self-hosted,linux]=ephemeral container on errai               |
 |              [self-hosted,windows]=dockur VM service                         |
 |              [self-hosted,macos]=dockur VM / Mac mini LaunchAgent            |
 |    signing inside build: sign-windows.ps1 (Azure Trusted Signing),           |
 |              package-flutter-macos-developerid.sh (codesign+notarytool),     |
 |              sign-linux-gpg.sh, sign-update-eddsa.sh                         |
 | 4. deploy    per-host jobs: download-artifact -> enumerate enabled lanes     |
 |              via `cepheus-build describe --json` -> `cepheus-build deploy`   |
 |              with verify-update-eddsa.sh gate before any feed publish        |
 +------------------------------------------------------------------------------+
        |                |                 |                    |
        v                v                 v                    v
  GitHub Release    STORE LANES       LINUX REPOS          UPDATE FEED
  (internal mirror, google_play.py    publish-apt-repo.sh  publish-update-feed.sh
   upload-release.sh) submit-msstore  publish-yum-repo.sh   sha256 + .sig -> R2
                     .ps1, make       publish-flatpak-      POST release-record ->
                     deploy-* (MAS/   repo.sh -> s3://R2     pd-updates admin API
                     TestFlight)        |                       |
                          |             v                       v
                          |   packages.printdeck.app   +------ errai Caddy ------+
                          v   (R2 custom domain)       | printdeck.app           |
                    Play / MS Store /                  |  /api/v1/updates/...    |
                    App Store review                   |  appcast-macos.xml      |
                                                       |  appcast-windows.xml    |
   cdn.printdeck.app  <--- R2 bucket --->              |  /check  /events        |
   {product}/{channel}/{version}/{file}                +-------------------------+
            ^                                                   ^
            |                                                   |
   downloads.printdeck.app (static site, same R2 bucket) ------ + (latest-version
   human download page, apt/yum/flatpak setup instructions        data, client-side)
```

Key properties:

- **Everything between the tag and the stores already exists as code** — the new surface is: the tag trigger, `gh release create`, the deploy stage, channel plumbing, and the download site.
- **Env-gated lanes mean partial credentials degrade gracefully** (unsigned + warning), but the new `preflight` job makes that an **explicit per-channel choice**, never a silent surprise.
- **`stable` releases are registered paused at 0% rollout** (publish-update-feed.sh default) — publishing and releasing-to-users are separate acts; un-pausing happens via the pd-updates admin API.

---

## 4. Secrets inventory

Legend — **Status**: EXISTS = provisioned today; PARTIAL = exists somewhere but wrong scope/unverified; **CREATE** = does not exist anywhere (confirmed by evidence pass).

| Secret(s) | Consumer (lane / script) | Created in | Lives in | Status |
|---|---|---|---|---|
| `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` | `google_play` lane; materialized into `android/key.properties` + `.jks` at job start (build.gradle.kts already loads `key.properties` when present) | `keytool -genkeypair` (upload key; enroll Play App Signing so Google holds the app key) | GitHub **org** Actions secrets + offline escrow of the .jks | **CREATE** — confirmed gap, `key.properties` absent everywhere |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` (stored as content; CI writes to temp **file path** — `google_play.py` rejects inline JSON) | `google_play` lanes (printdeck-app enabled; anvil/colorwake disabled) via `cepheus_build/deploy/google_play.py` | GCP service account + Play Console grant | GitHub org secret | **CREATE** |
| `PARTNER_CENTER_TENANT_ID` / `CLIENT_ID` / `CLIENT_SECRET` / `APP_ID` | `microsoft_store` lane -> `scripts/submit-msstore.ps1` | Entra app linked to Partner Center | printdeck-app repo secrets today; move to org | PARTIAL — used by the proven `frontend-windows-release.yml`; verify, add colorwake `APP_ID` later |
| `WINDOWS_CERT_BASE64`, `WINDOWS_CERT_PASSWORD` | MSIX packaging (`dart run msix:create`) in printdeck-app Windows release | existing .pfx | printdeck-app repo secrets | PARTIAL — exists per workflow usage; verify |
| `AZURE_TENANT_ID` / `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` + `TRUSTED_SIGNING_ENDPOINT` / `TRUSTED_SIGNING_ACCOUNT` / `TRUSTED_SIGNING_CERT_PROFILE` | `sign-windows.ps1` (Authenticode for direct-download .exe; all 6 required) — already declared in `app-build.yml` secrets contract | Azure Trusted Signing signup (eligibility open) | GitHub org secrets | **CREATE** — blocked on Azure signup (open question Q2) |
| `APPSTORE_CONNECT_KEY_ID` / `ISSUER_ID` / `PRIVATE_KEY` (b64 .p8), `APPSTORE_TEAM_ID`, profile-name vars | `testflight_ios` / `testflight_macos` / `mac_app_store` lanes; `.p8` also at `~/.appstoreconnect/private_keys/` on the mac runner (printdeck-app Makefile hardcodes it) | App Store Connect (team J2W5M4CY69) | printdeck-app + colorwake repo secrets today; move to org; .p8 file in mac runner golden image | PARTIAL — used by existing workflows; verify + consolidate naming (colorwake uses `_PRIVATE_KEY_BASE64`) |
| Developer ID Application / Apple Distribution / Mac Installer Distribution certs, provisioning profiles, `AC_NOTARY` notarytool keychain profile | `package-flutter-macos-developerid.sh`, `package-flutter-macos-appstore.sh`, xcodebuild archive steps | Apple Developer portal; `xcrun notarytool store-credentials` | **macOS runner keychain only** (the signing enclave; snapshot after provisioning) | **CREATE** on the runner — macOS VM not provisioned yet |
| `MACOS_SIGN_ID`, `MACOS_NOTARIZE_APPLE_ID` / `_PASSWORD` / `_TEAM_ID` (CI-friendly env shape, already plumbed in `app-build.yml`) | deckhand-style DMG sign+notarize; target shape for anvil/colorwake migration | Apple ID app-specific password / ASC API key | GitHub org secrets | PARTIAL — deckhand release.yml consumed them; verify |
| `GPG_SIGNING_KEY` (+ `GPG_SIGNING_KEY_ID`, `GPG_SIGNING_KEY_PASSPHRASE`) | `sign-linux-gpg.sh`, `publish-apt-repo.sh`, `publish-yum-repo.sh`, `publish-flatpak-repo.sh`, `package-flutter-linux-*.sh` | `gpg --full-generate-key` (one org packaging key) | GitHub org secrets + offline escrow; public key published on download site | **CREATE** |
| `CL_UPDATE_ED25519_PRIVATE_KEY` (b64 32-byte seed) | `sign-update-eddsa.sh` via `publish-update-feed.sh`; gate `verify-update-eddsa.sh` | `scripts/cl-update-keygen.sh`; public key -> `printdeck-contracts/registry/update-distribution.json` (current entry `cl-update-ed25519-2026-06` may be regenerated pre-GA — no clients shipped) | GitHub org secret ONLY + offline escrow (loss = no verified updates; rotation = dual-key bridge) | **CREATE** (regenerate; registry pubkey is placeholder-grade) |
| `CL_UPDATE_PUBLISH_TOKEN` | `publish-update-feed.sh` bearer for `POST /api/v1/updates/admin/releases` | mint a random token | GitHub org secret; **must equal** `PRINTDECK_UPDATES_PUBLISH_TOKEN` in errai's `/media/cl-webapp/printdeck/.env` (currently empty = admin lane fails closed) | **CREATE** |
| `PRINTDECK_UPDATES_ED25519_PUBLIC_KEY` | pd-updates compose env (informational) | from keygen above | errai `.env` | **CREATE** |
| `R2_ACCOUNT_ID` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_BUCKET` | `publish-update-feed.sh`, `publish-{apt,yum,flatpak}-repo.sh` (s3 path), download-site sync — already declared in `app-build.yml` | Cloudflare dashboard (bucket + API token) | GitHub org secrets | **CREATE** — no Cloudflare bucket exists |
| `APT_REPO_TARGET` / `YUM_REPO_TARGET` / `FLATPAK_REPO_TARGET` = `s3://$R2_BUCKET/{apt,yum,flatpak}` | repo publish lanes | decision L2 (made) | GitHub org Actions **variables** (not secret) | **CREATE** |
| `CL_UPDATE_API_BASE` (`https://printdeck.app`), `CL_UPDATE_CDN_BASE` (`https://cdn.printdeck.app`) | publish-update-feed.sh | script defaults already correct | nothing to set (defaults) | EXISTS (defaults) |
| `GITHUB_TOKEN` (ambient) | `github_release` lanes (`upload-release.sh`, `gh release create`) | automatic | per-job; caller sets `permissions: contents: write` | EXISTS |
| `CEPHEUS_READ_TOKEN` | private first-party git/Go fetches in `app-build.yml`; errai image builds | org read PAT | GitHub org secret (+ `gh auth token` on errai) | EXISTS |
| Org-admin PAT for runner registration | ephemeral Linux runner re-register loop | GitHub PAT (admin:org, self-hosted runners) | errai `/media/cl-webapp/printdeck/.env.runner` (root-readable) ONLY — never in images | **CREATE** |

---

## 5. Phased implementation plan

Sizes: S < 0.5 day, M = 0.5–2 days, L = 2–5 days. Tasks within a phase are parallelizable unless a dependency is listed.

### Phase 0 — Prerequisites, accounts, keys (mostly human/ops; start immediately, runs parallel to Phases 1–2)

| # | Task | Repo / where | Size | Deps |
|---|------|--------------|------|------|
| 0.1 | **Android upload keystore**: `keytool -genkeypair` (RSA 4096, 25y+), enroll Play App Signing on first console upload; store the 4 `ANDROID_*` org secrets; escrow the `.jks` offline. Add a `key.properties`-materialization step (decode secrets -> file -> build -> delete) to the release workflow (lands in 2.2). `build.gradle.kts` already consumes the file — no Gradle work. | printdeck-app secrets + cepheus-build workflow | S | none |
| 0.2 | **GPG packaging key**: generate one org key, set `GPG_SIGNING_KEY`/`_ID`/`_PASSPHRASE` org secrets, escrow offline. Consumers (`sign-linux-gpg.sh` `ensure_gpg_key()`, all three repo publishers) need zero changes. | org secrets | S | none |
| 0.3 | **Ed25519 update key**: run `scripts/cl-update-keygen.sh` (regenerate — pre-GA regeneration is sanctioned in the registry note); set `CL_UPDATE_ED25519_PRIVATE_KEY` org secret; commit new public key to `printdeck-contracts/registry/update-distribution.json` (`current`, keep `next` slot for rotation); escrow seed offline. | printdeck-contracts + org secrets | S | none |
| 0.4 | **Cloudflare provisioning**: confirm/migrate the `printdeck.app` DNS zone to Cloudflare (open question Q1 — step zero); create the R2 bucket; bind custom domains `cdn.printdeck.app`, `packages.printdeck.app`, `downloads.printdeck.app`; mint R2 API token; set `R2_*` org secrets + `*_REPO_TARGET` org variables. Watch errai's ACME: if the apex is orange-clouded, switch Caddy to DNS-01 or Cloudflare origin certs. | Cloudflare + org secrets | M | DNS answer (Q1) |
| 0.5 | **pd-updates activation**: mint `CL_UPDATE_PUBLISH_TOKEN`; set it as org secret AND as `PRINTDECK_UPDATES_PUBLISH_TOKEN` + `PRINTDECK_UPDATES_ED25519_PUBLIC_KEY` in errai's `.env`; `docker compose up -d pd-updates`; smoke-test `POST /admin/releases` with a dummy record + `GET appcast-macos.xml`. Fix the stale "nothing built yet" header in `cepheus-build/docs/auto-update.md` while here. | errai + cepheus-build docs | S | 0.3 |
| 0.6 | **Azure Trusted Signing signup** (eligibility check first — open question Q2). On success set the 6 `AZURE_*`/`TRUSTED_SIGNING_*` org secrets; `sign-windows.ps1` then works with zero changes. Fallback: purchase an OV cert and add a signtool path. Windows ships unsigned-with-warning until resolved (MSIX Store path unaffected — Store signs). | Azure + org secrets | M (mostly waiting) | Q2 |
| 0.7 | **Apple account prep**: confirm ASC API key validity; consolidate secret names (`APPSTORE_CONNECT_PRIVATE_KEY` everywhere, drop colorwake's `_BASE64` variant) and promote to org secrets; decide Mac mini purchase (open question Q3). | Apple / org secrets | S | Q3 |

### Phase 1 — Runner fleet (decision-independent of Phase 0; can start now)

| # | Task | Repo / where | Size | Deps |
|---|------|--------------|------|------|
| 1.1 | **First-party Linux runner image**: new `cepheus-build/docker/runner/` — Dockerfile `FROM cepheus-build-linux` + actions/runner + vendored ephemeral-re-register entrypoint (copy the MIT entrypoint logic in-tree; pattern proven at `printdeck-server/docker-compose.yml:1666` `EPHEMERAL: "true"`). Org-scoped (`RUNNER_SCOPE=org`), labels `self-hosted,linux,x64` only. | cepheus-build | M | none |
| 1.2 | **Deploy on errai**: compose service (in the printdeck-server stack or a small standalone compose), `--scale github-runner=2`, docker socket mount (required: `docker-publish.yml` builds 16 images), named volumes for pub/gradle/cargo caches, resource limits (errai also runs prod). Org-admin PAT in `.env.runner`. **Retire the repo-scoped printdeck-server runner.** | printdeck-server compose + errai | M | 1.1 |
| 1.3 | **Windows VM runner**: in the dockur Windows VM (errai :2322), install actions/runner via `config.cmd --runasservice`, org scope, labels `self-hosted,windows,x64`. Document in new `cepheus-build/docs/runners.md`. No signing material at rest (Azure signing is cloud-side). | dockur Windows VM + cepheus-build docs | S | VM exists (it does) |
| 1.4 | **macOS runner**: complete dockur macOS VM first-boot (pending task #6) — or Mac mini if Q3 resolves fast; `./svc.sh install` LaunchAgent + auto-login; provision the signing enclave: import Developer ID Application / Apple Distribution / Mac Installer certs, `xcrun notarytool store-credentials AC_NOTARY`, `.p8` at `~/.appstoreconnect/private_keys/`; **snapshot as golden image**. Labels `self-hosted,macos` only. | dockur macOS VM / Mac mini | L | VM first-boot; certs (0.7) |
| 1.5 | **Label hygiene**: delete the `macbook-pro` label requirement from `printdeck-app/.github/workflows/frontend-macos-release.yml` (superseded in Phase 4 anyway) and the bespoke `printdeck` label from the old compose runner. | printdeck-app, printdeck-server | S | none |
| 1.6 | **Org policy**: enforce SHA-pinned actions org-wide (everything is already pinned per IMPROVEMENTS #28 — make it policy); confirm Default runner group blocks public-repo access (default). | GitHub org settings | S | none |

### Phase 2 — Release workflow skeleton + first lane end-to-end (cheapest proof: **deckhand `github_release`, Linux row only**)

| # | Task | Repo / where | Size | Deps |
|---|------|--------------|------|------|
| 2.1 | **CLI: channel + tag plumbing**: add `CBUILD_CHANNEL` to the `build_env()` contract (`cepheus_build/environment.py`); add `cepheus-build release -p <product> [--channel beta]` command (`compute_stamp` -> annotated tag `v$VER-$NUM` / `beta-v$VER-$NUM` -> `git push origin <tag>`; use the https-push token form for keyless-SSH repos). | cepheus-build (`commands.py`, `environment.py`) | M | none |
| 2.2 | **New reusable workflow `cepheus-build/.github/workflows/app-release.yml`** (workflow_call). Jobs: (a) `prepare` — parse `GITHUB_REF_NAME` -> outputs `version`/`build_number`/`channel` (tag authoritative; `v*`->stable, `beta-v*`->beta, `workflow_dispatch`/schedule input->nightly); (b) `preflight` — secrets gate (see 2.3); (c) `release` — `gh release create "$TAG" --verify-tag --title --notes-from-tag` (THE missing step every `github_release` lane assumes); (d) `build` — nested `uses: ./.github/workflows/app-build.yml` passing `CBUILD_VERSION`/`CBUILD_BUILD_NUMBER`/`CBUILD_CHANNEL` overrides + `secrets: inherit`; (e) `deploy` — per-host matrix: `actions/download-artifact`, enumerate enabled lanes via `cepheus-build describe -p <product> --json`, run `cepheus-build deploy -p <product> <lane>` for each, with `verify-update-eddsa.sh <pubkey> <files>` as a mandatory gate before any `publish-update-feed.sh` lane. Extend the secrets contract with the store secrets `app-build.yml` doesn't declare (`PARTNER_CENTER_*`, `APPSTORE_*`, `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`, `ANDROID_*`). All actions SHA-pinned. | cepheus-build | L | 2.1, 1.2 (linux runner) |
| 2.3 | **Deploy validation + handoff in the CLI**: (a) `deploy --validate` — checks `required_env` + host + enabled WITHOUT executing (closes the hole where `--dry-run` skips required_env, `commands.py:601`); `preflight` runs it for every enabled lane and fails the release on missing secrets — no more green-but-unsigned; (b) `CBUILD_ARTIFACTS_DIR` env contract so lanes can consume downloaded artifacts instead of rebuilding (full rework of printdeck-app's `make deploy-*` rebuild habit lands in Phase 4); (c) a `deploy --enabled-only` / lane-enumeration helper so the workflow doesn't hard-error on `enabled=false` lanes. | cepheus-build (`commands.py`) | M | none |
| 2.4 | **Caller template + fixes**: add `cepheus-build/templates/github/app-release.yml` (thin caller: tag trigger + dispatch fallback, `permissions: contents: write`, `concurrency: release`, `secrets: inherit`); fix the stale `printdeck` slug in `templates/github/app-build.yml:11`. | cepheus-build | S | 2.2 |
| 2.5 | **End-to-end proof on deckhand**: replace deckhand-app's bespoke 28 KB `release.yml` with the thin caller (add the missing `secrets: inherit` to its `shared-build.yml` too); run `cepheus-build release -p deckhand`; verify: tag -> GH release created -> linux build -> `upload-release.sh` uploads deb/rpm/AppImage (`nullglob` exit-0 tolerates the not-yet-online win/mac rows). **This is the pipeline's first green light and needs zero external store accounts.** | deckhand-app | M | 2.2–2.4 |
| 2.6 | **Fix foundry's lane**: replace the raw unquoted `gh release upload` in `products/foundry.toml` with `upload-release.sh` + quoted globs (it breaks on any missing artifact); add foundry's thin release caller + `secrets: inherit`. | cepheus-build, foundry | S | 2.4 |
| 2.7 | **Re-baseline docs**: `docs/auto-update.md` phase statuses (pd-updates is BUILT + DEPLOYED), `INSTALLERS.md` open items (Linux repo host = RESOLVED to R2), new `docs/release-pipeline.md` pointing at this plan. | cepheus-build | S | 2.5 |

### Phase 3 — Download site + update feed live (needs Phase 0.3–0.5 done)

| # | Task | Repo / where | Size | Deps |
|---|------|--------------|------|------|
| 3.1 | **Flip `update_publish` lanes `enabled=true`** for deckhand, anvil, colorwake-studio, printdeck-app (`products/*.toml`). `publish-update-feed.sh` already does sha256 -> EdDSA sign -> R2 upload -> release-record POST, registering `paused=true rollout_pct=0`. First real publish: a deckhand AppImage/DMG; verify with `verify-update-eddsa.sh` + `curl` of the appcast/check endpoints. | cepheus-build | S | 0.3–0.5, 2.5 |
| 3.2 | **Complete `publish-update-feed.sh` Phase-2 TODOs**: generate + upload `.zsync` for AppImages (zsyncmake; R2 supports Range — required for AppImageUpdate) and populate `zsync_url`; enrich Android records with `version_code` + `apk_signer_sha256`. Add **never-overwrite enforcement**: fail if the R2 key already exists (immutability is contractual — MS Store MSI/EXE rule + release-record contract). | cepheus-build | M | 3.1 |
| 3.3 | **Flip Linux repo lanes**: set `APT/YUM/FLATPAK_REPO_TARGET` org variables to `s3://$R2_BUCKET/{apt,yum,flatpak}`; flip `apt_repo`/`yum_repo`/`flatpak_repo` `enabled=true` on anvil/colorwake/deckhand. Harden upload ordering in `publish-apt-repo.sh` (sync `pool/` before `dists/` so clients never see metadata for missing debs; same for OSTree summary) and add `--generate-static-deltas` to the flatpak publisher. Publish the `.flatpakrepo` file (embedding the GPG key) + apt/yum `.repo`/sources snippets to `packages.printdeck.app`. | cepheus-build | M | 0.2, 0.4 |
| 3.4 | **Download site**: new `cepheus-build/site/downloads/` — small static HTML/JS (no framework needed; i18n-ready strings), served from the R2 bucket behind `downloads.printdeck.app`. Latest-version links resolved client-side from pd-updates' public endpoints (`/api/v1/updates/{product}/{channel}/...` — releases/channels are already modeled; no new backend). Pages: per-product download cards (DMG/EXE/AppImage/deb/rpm/flatpak), apt/yum/flatpak setup instructions, GPG public key, checksums/sig links. Deploy = `aws s3 sync` job in cepheus-build's own workflow on push to main. | cepheus-build | M–L | 0.4 |
| 3.5 | **Track the errai Caddy overlay**: bring `Caddyfile.frontend` + `docker-compose.override.yml` (currently untracked on errai) into printdeck-server as committed overlay files; remove or annotate the dangling `deploy.printdeck.app -> watchtower` vhost. Orange-cloud `printdeck.app` for feed edge-caching (short TTL on appcast/check). | printdeck-server + errai | M | none |

### Phase 4 — Remaining stores (per-lane flips; each independent once Phase 2 skeleton + its Phase 0 secret exists)

| # | Task | Repo / where | Size | Deps |
|---|------|--------------|------|------|
| 4.1 | **printdeck-app migration (the big one)**: add the thin `release.yml` caller (printdeck-app has NO cepheus-build caller today — its 9 bespoke `frontend-*` workflows include two mislabeled "tag-triggered" release files that are dispatch-only); port the proven MSIX/Store and xcodebuild/ASC steps from `frontend-windows-release.yml` / `frontend-macos-release.yml` into the lane scripts; rework `make deploy-*` targets to consume `CBUILD_ARTIFACTS_DIR` artifacts instead of rebuilding (build once, deploy from the artifact); delete superseded workflows (no back-compat). Add a `github_release` lane (flagship currently has NO direct-download publication path) using `upload-release.sh`. | printdeck-app + cepheus-build | L | 2.2–2.3, 1.3–1.4 |
| 4.2 | **Google Play first upload**: materialize keystore (0.1) + service account (Phase 0); **consolidate printdeck-app's Makefile hand-rolled uploader onto `cepheus_build.deploy.google_play`** (retry/backoff, CBUILD_DRY_RUN, `--track internal`); verify Play account type (open question Q5); first internal-track upload, then promote. Later: flip anvil/colorwake `google_play` lanes. | printdeck-app, cepheus-build | M | 0.1, 4.1 |
| 4.3 | **Microsoft Store robustness**: make `submit-msstore.ps1` re-run-safe — delete any pending submission before creating (the v2.0 create call 4xxs today), or migrate to `msstore-cli` (Microsoft's maintained cross-platform CLI; same Entra credentials). First automated MSIX submission for printdeck-app. | cepheus-build | M | 1.3, 4.1 |
| 4.4 | **Mac App Store modernization**: replace the deprecated `xcrun altool --upload-app` path in `package-flutter-macos-appstore.sh` (and printdeck-app's Makefile) with ASC-API-key auth via `xcodebuild -exportArchive method=app-store-connect destination=upload` (the proven `frontend-macos-release.yml` pattern) — altool's notary endpoint is already dead and the upload path is legacy. Then printdeck-app `mac_app_store` + colorwake `testflight_macos` e2e. | cepheus-build, printdeck-app, colorwake-studio | M | 1.4 |
| 4.5 | **Notarized DMG for anvil/colorwake**: migrate their `<PREFIX>_NOTARY_PROFILE` keychain-profile style to the CI-friendly env shape (`MACOS_NOTARIZE_*`, already in the `app-build.yml` secrets contract) OR rely on `AC_NOTARY` provisioned in the golden image (1.4) — pick env-driven (deckhand shape) per build-proper; one shared change in `package-flutter-macos-developerid.sh`. | cepheus-build | M | 1.4 |
| 4.6 | **Windows Authenticode live**: when 0.6 lands, the six secrets flow through `app-build.yml` -> `sign-windows.ps1` with zero code changes; verify a signed anvil/deckhand `.exe` passes SmartScreen; this also unblocks Windows auto-update GA later. | org secrets only | S | 0.6 |
| 4.7 | **TestFlight lanes**: colorwake `testflight_ios`/`testflight_macos` (its `scripts/testflight.sh` already parses `ios-v*`/`macos-v*` tag names — give it the tag trigger it was written for via the caller); printdeck-app `testflight_ios`. | colorwake-studio, printdeck-app | S–M | 1.4, 0.7 |

### Phase 5 — Hardening + ops

| # | Task | Repo / where | Size | Deps |
|---|------|--------------|------|------|
| 5.1 | **Nightly channel**: scheduled thin caller per product invoking `app-release.yml` with `channel=nightly` (no tag; version from `compute_stamp`; publishes to `{product}/nightly/...`, never creates a GH release). Start with deckhand only. | product repos | M | Phase 3 |
| 5.2 | **Re-run idempotency tests**: re-run a tag workflow and assert identical `CBUILD_VERSION`/`BUILD_NUMBER` (tag-authoritative), `upload-release.sh --clobber` semantics, never-overwrite R2 behavior (re-publish must fail loudly, not silently mutate), msstore pending-submission handling. | cepheus-build | M | Phase 4 |
| 5.3 | **Workflow smoke**: weekly scheduled run of `cepheus-build/ci.yml` (currently dispatch-only) building one tiny target per OS so reusable-workflow/runner rot is caught before release day. | cepheus-build | S | Phase 1 |
| 5.4 | **Key lifecycle**: document + drill the dual-key Ed25519 rotation (registry `current`/`next` model — never rotate together with an OS-cert change); confirm offline escrow of Android keystore, GPG key, Ed25519 seed; runner VM snapshot refresh cadence. | cepheus-build docs | S | Phase 0 |
| 5.5 | **Mac mini migration** (if interim dockur macOS was used): identical LaunchAgent + keychain setup; labels unchanged (`x64` was deliberately never required). Decommission the EULA-violating VM before GA. | hardware | M | Q3 |
| 5.6 | **Runner observability**: queue-time alerting (a macOS job queuing >30 min means the runner is down — jobs fail only after 24 h), errai resource-limit tuning under build+prod load. | errai / monitoring | S–M | Phase 1 |

---

## 6. Per-product rollout order

**printdeck-app is NOT first** — it is the flagship but also the largest migration (no shared-build caller, 9 bespoke workflows, 4 live store lanes, and the Android keystore gap). Prove the skeleton on the lowest-risk product, then expand one credential family at a time, so by the time printdeck-app migrates the pipeline is boring.

| Order | Product | Phase | Lanes lit | Why here |
|-------|---------|-------|-----------|----------|
| 1 | **deckhand** | 2 | `github_release` (then `update_publish`, apt/yum/flatpak in 3) | Cheapest proof: desktop-only, the ecosystem's only existing tag-trigger precedent, lane already `enabled=true`, needs only the ambient `GITHUB_TOKEN`; also the AppImage/zsync flagbearer for Phase 3.2 |
| 2 | **foundry** | 2 | `github_release` (fixed) | One lane, linux-pinned, exercises the multi-artifact (CLI + MCU + RAUC) upload path; fixes its broken raw `gh upload` |
| 3 | **anvil** | 3 | `github_release` + `update_publish` + apt/yum/flatpak + DMG/EXE signing | Full desktop packaging surface (Wave-D scripts exist); first product through the GPG + Ed25519 + notarization gauntlet without store-account coupling |
| 4 | **colorwake-studio** | 3–4 | adds `testflight_ios`/`testflight_macos` (already `enabled=true`), later `google_play`/`microsoft_store` | First Apple-store path; its `testflight.sh` already expects tag names — minimal-risk store proof |
| 5 | **printdeck-app** | 4 | `google_play`, `microsoft_store`, `mac_app_store`, `testflight_ios`, `update_publish`, new `github_release` | Flagship gets the proven pipeline; biggest migration (4.1) lands once runners, secrets gate, and store submitters are all battle-tested. Phase 0.1 (keystore) starts day one regardless |
| 6 | **printdeck-server / printdeck-agent** | — | none (no store lanes by design) | Server ships via `docker-publish.yml` -> GHCR -> compose deploy (unchanged); agent releases from its own repo CI. Optionally adopt a thin `app-release.yml` caller later for tagged agent binaries — not on the critical path |

---

## 7. Open questions for the owner

**ANSWERED 2026-06-12:**

1. **DNS:** printdeck.app is already on Cloudflare DNS. Phase 3 (R2 + custom domains) is unblocked; first step is an R2 bucket + API token.
2. **Windows signing:** pursue **Azure Trusted Signing** (onboarding runbook to be drafted); OV cert remains the fallback if eligibility fails. MS Store MSIX needs neither.
3. **macOS hardware:** the dockur macOS VM serves as a **documented interim** for signing/CI; migrate to Apple hardware before GA (caveat stands in cross-os-builds.md).
4. **Runner PAT:** errai's gh token (CepheusLabs account) mints registration tokens; in production at /media/cl-webapp/printdeck/.env.runner.
5. **Google Play:** the developer account is an **organization** — no closed-test gate; production publishing unblocks once the android keystore + Play service account exist (Phase 0).
