# Desktop Auto-Update — Design

How the Cepheus Labs Flutter apps (**Anvil**, **Colorwake Studio**, **Deckhand**,
**Printdeck**) check for, download, verify, and apply their own updates — the
*demand* side that consumes the signed installers [`cepheus-build` already
publishes](installers.md).

> Status: **design / proposed**. Nothing here is built yet.
> Companion docs: [installers.md](installers.md) (what we build & sign),
> [stores.md](stores.md) (store lanes). This doc adds the client-side updater
> plus the feed that bridges the two.
>
> **Authoritative data contracts (frozen, Phase 0):** the field names, schemas,
> registry, and signing scheme below are governed by **Update Contracts v1** in
> `printdeck-contracts` (under `ecosystem/`). §3 and §4 of this doc are now
> *narrative*; the normative source is the schemas and registry linked in
> [Phase 0 — frozen contracts](#phase-0--frozen-contracts).

## The gap this closes

`cepheus-build` is the **supply side** and it's mature: it produces signed
installers (notarized `.dmg`, Azure-signed `.exe`, GPG `.deb`/`.rpm`/Flatpak/
AppImage) and publishes them to GitHub Releases + scaffolded self-hosted
apt/yum/flatpak repos. Versioning is pubspec `x.y.z+build`, tag `v<version>-<build>`.

There is currently **zero client-side update code** in any app. This design is
the missing **demand side**: apps that check → download → verify → apply, plus a
**feed/control plane** that decides *what* version each install should get.

## Locked decisions (with Evan, 2026-06-06)

| Dimension | Choice |
|---|---|
| Feed + control plane | **Self-hosted on `printdeck.app`** (Go service behind the gateway) |
| Binary hosting | **CDN** — Cloudflare R2 / S3 (cheap egress; binaries off origin) |
| Update UX | **Auto-download, install on quit** (Sparkle-style) |
| Channels | **stable + beta + nightly** |

Self-hosting the control plane is what unlocks **%-staged rollout**, **instant
pause**, **update telemetry**, and a **minimum-version kill switch** — none of
which a static GitHub-Releases feed can do.

---

## 1. Architecture — three planes

```
  SUPPLY (cepheus-build + CI)              CONTROL PLANE (printdeck.app, Go)
 ┌─────────────────────────────┐         ┌──────────────────────────────────┐
 │ build signed installers ✅   │         │  pd-updates service               │
 │ NEW: update_publish lane     │         │   GET /appcast.xml  (mac/win)     │
 │  • sha256 + EdDSA-sign each  │ POST    │   GET /check        (linux/android)│
 │    artifact                  │ release │   POST /events      (telemetry)   │
 │  • upload binaries → R2      ├────────►│   POST /admin/releases (CI auth)  │
 │  • register release row      │ manifest│   releases table + rollout/pause/ │
 └──────────────┬───────────────┘         │   min-version + bucketing logic   │
                │ binaries                 └──────────────┬───────────────────┘
                ▼                                          │ decision + URLs
   DISTRIBUTION (R2 / S3 + CDN)                            │
 ┌─────────────────────────────┐                          ▼
 │ {product}/{channel}/{ver}/   │◄───────── download ──── CLIENTS (cl_updater)
 │   *.dmg *.exe *.AppImage     │                     ┌──────────────────────┐
 │   *.zsync *.apk + .sig       │                     │ mac/win → auto_updater│
 └─────────────────────────────┘                     │ linux  → detect/repo  │
                                                      │ appimg → zsync+verify │
                                                      │ android→ PackageInst. │
                                                      └──────────────────────┘
```

- **Supply plane** — `cepheus-build` + CI. Already builds signed installers; we
  add one lane that hashes, EdDSA-signs, uploads binaries to R2, and registers a
  release with the control plane.
- **Control plane** — a small Go service (`pd-updates`) behind `pd-gateway`,
  sibling to `pd-auth`/`pd-core`. The brain: given (product, channel, platform,
  arch, current version, install id) it decides *is there an update, which one,
  where, and is it mandatory*. Owns rollout %, pause, min-version, telemetry.
- **Distribution plane** — R2/S3 + CDN holds the bytes. Immutable layout
  `{product}/{channel}/{version}/{file}`. Control plane returns CDN URLs
  (optionally short-lived signed URLs if we ever gate downloads by license).

---

## 2. Per-platform mechanism

Flutter desktop has **no built-in updater**, so each OS uses the idiomatic path:

| Platform | Install form | Update mechanism |
|---|---|---|
| **macOS** | `.dmg` → `.app` | **Sparkle** via the `auto_updater` plugin: reads the appcast, EdDSA-verifies, swaps the `.app`, relaunches. Needs the app signed+notarized — ✅ already true. |
| **Windows** | `.exe` (Inno Setup) | **WinSparkle** via the same plugin + **same appcast**: downloads the new installer `.exe`, runs it silently, relaunches. Wants the `.exe` Azure-signed (pending) to avoid SmartScreen on each update. |
| **Linux — apt/yum** | `.deb`/`.rpm` | **The OS package manager** updates from your signed repos. App does *not* self-replace; it detects a newer version via `/check` and nudges (optional one-click `pkexec`). |
| **Linux — Flatpak** | flatpak | **Flatpak/GNOME Software** auto-updates from your OSTree repo. App detects + nudges only — never self-updates a sandboxed install. |
| **Linux — AppImage** | `.AppImage` | **zsync/AppImageUpdate**: embed update-info at build; in-app download (delta), EdDSA+sha256 verify, atomic replace of `$APPIMAGE`, relaunch. |
| **Android (non-store)** | `.apk` (`direct` flavor) | Custom: `/check` → download APK → verify pinned signer cert + sha256 → `PackageInstaller` (needs `REQUEST_INSTALL_PACKAGES`). Play-flavor builds use Play's own update path. |

**The elegant core:** macOS + Windows — the bulk of desktop — share *one*
appcast format and *one* plugin (`auto_updater`, the leanflutter package wrapping
Sparkle + WinSparkle). Linux is mostly "the repos you already build *are* the
updater." Only **AppImage** and **Android sideload** are bespoke download-and-apply
paths.

> **Not Shorebird.** Shorebird code-push only swaps Dart; it can't update the
> Rust FFI (Anvil/Colorwake) or Go sidecar (Deckhand) and is mobile-oriented.
> Wrong tool for native-heavy desktop.

---

## 3. Trust & integrity — the security spine

Three independent layers. The updater's real trust anchor is the **EdDSA update
key**, *not* OS code-signing:

1. **Transport** — HTTPS, with cert pinning to `printdeck.app` for the control
   plane.
2. **Artifact signature (primary anchor)** — every artifact is signed at build
   time with a project **Ed25519 update key** (Sparkle's `generate_keys` /
   `sign_update`; WinSparkle uses the same EdDSA scheme). The **public key is
   compiled into the app** (copied from the contracts registry). The client
   verifies the EdDSA signature on the downloaded file *before applying*. This is
   the cross-platform integrity guarantee and the *only* one for AppImage,
   Android, and the in-app downloader. The record carries a `signature_target`
   that is **always `file_bytes`**: the signature covers the raw file bytes for
   every platform. AppImage clients run zsync to reassemble the file and then
   verify those same raw bytes — there is no pre-hash variant.
3. **OS code-signing (defense in depth)** — notarized DMG, Azure-signed `.exe`,
   GPG-signed Linux repos. You already have these; they satisfy Gatekeeper/
   SmartScreen but are not what the updater relies on.

**Key custody.** The Ed25519 *private* key is the **base64 of the raw 32-byte
seed**, living **only in CI secrets** (`CL_UPDATE_ED25519_PRIVATE_KEY`), never on
dev machines or in the repo. (Generate it with
`scripts/cl-update-keygen.sh <slug>`; it prints the seed once for capture and
writes a gitignored `keys/` copy you then delete. Sign/verify with
`scripts/sign-update-eddsa.sh` / `scripts/verify-update-eddsa.sh` — pynacl,
byte-identical to Sparkle's `sign_update` from the same seed. 96-byte legacy keys
are rejected.) The canonical **public** key(s) live in the contracts registry
`registry/update-distribution.json` under `signing_keys`, and app builds copy
from there.

**Rotation = dual-key bridge (Sparkle constraint), NOT "trust two keys".**
Sparkle/WinSparkle each trust **exactly one** EdDSA key at a time, so we cannot
simply trust current + next. To rotate: ship a bridge update **signed with the
OLD key** whose app bundle embeds the **NEW** `SUPublicEDKey`; keep the old key
until telemetry confirms the fleet took the bridge build. **Never change the
EdDSA key AND the OS code-signing cert in the same update.** The registry models
the transition by carrying two entries (`status: current` and `status: next`),
and `release-record.signing_key_id` records which key signed each artifact so CI
can audit it. Back the seed up securely — losing it means you can't ship verified
updates.

**Min-version gate / kill switch.** The control plane returns `min_supported_version`
per product. A running app below it is told the update is **mandatory** and
blocks normal use until updated. Essential because these talk to the
`printdeck.app` backend — it lets you retire a broken or insecure client fleet-wide.

**Downgrade protection.** The client refuses any "update" whose version ≤ current,
defeating feed-replay/rollback attacks.

---

## 4. Control plane (`pd-updates`, Go behind `pd-gateway`)

Start as a module in `pd-core` if that's faster; the clean shape is a sibling
service so release/CDN concerns stay out of core.

### Data model

The `releases` row model **is** the canonical `printdeck.release-record/1`
schema — columns map 1:1 to its snake_case field names (no synonyms; it is
always `ed_signature`, never `signature`/`sig`). The schema doubles as the
`POST /api/v1/updates/admin/releases` request body. See the frozen contract:
[`schemas/printdeck.release-record.v1.json`][rr] (full field set, types, enums,
and required array in **Update Contracts v1 §0/§1**), and the golden
[`goldens/distribution/release-record-anvil-macos.json`][rr-gold].

The `update_events` telemetry table **is** the frozen
[`printdeck.update-event/1`][ue] schema (the `POST /api/v1/updates/events` body):
`install_id, product, channel, from_version, to_version, platform, arch, event, ts`
where `event` is the telemetry enum in
[`registry/update-distribution.json`][reg] (`check`, `offered`,
`download_started`, `download_completed`, `verify_failed`, `apply_started`,
`applied`, `error`). Golden: [`update-event-applied.json`][ue-gold].

### Endpoints

| Method | Path | Who | Purpose |
|---|---|---|---|
| `GET` | `/api/v1/updates/{product}/{channel}/appcast-{macos,windows}.xml?current=&install_id=&build=` | mac/win clients (Sparkle/WinSparkle) | Rendered, EdDSA-signed appcast honoring rollout + min-version |
| `GET` | `/api/v1/updates/{product}/check?channel=&platform=&arch=&current=&build=&install_id=` | linux-AppImage / Android | JSON decision (below) |
| `POST` | `/api/v1/updates/events` | all clients | Telemetry ingest (opt-out respected) |
| `POST` | `/api/v1/updates/admin/releases` | CI (bearer `CL_UPDATE_PUBLISH_TOKEN`) | Register a release after upload |
| `PATCH`| `/api/v1/updates/admin/releases/{id}` | ops | Set `rollout_pct` / `paused` / `mandatory` |

`/check` response — the server's rollout/min-version *decision* rendered to JSON
for AppImage + Android. The shape is the frozen
[`schemas/printdeck.update-check-response.v1.json`][ucr]: every artifact field
reuses the canonical release-record names; `min_supported_version` is **always
echoed** (the kill switch) even when `update=false`; when `update=true` the
artifact block (`version`, `build`, `url`, `size`, `sha256`, `ed_signature`,
`signature_target`) is required — and **forbidden** when `update=false`. It adds
AppImage fields (`zsync_url`, `appimage_url`, `block_size`) and Android fields
(`apk_url`, `apk_signer_sha256` — pin the *signing cert*, not the file hash —,
`application_id`, `version_code`, `install_min_sdk`, `target_sdk`,
`flavor`). The response also carries optional, nullable `envelope_signature` +
`expires_at` fields, reserved for when the decision envelope itself is signed
(see §8). Goldens: [`update-check-appimage-available.json`][ucr-appimg]
(`signature_target=file_bytes`) and
[`update-check-android-current.json`][ucr-android] (`reason=up_to_date`,
kill-switch floor echoed). The appcast (mac/win) is rendered from the same
release records — see the field mapping in **Update Contracts v1 §4**, the
[`printdeck.appcast.v1.xsd`][xsd] render contract, and the goldens
[`appcast-anvil-stable-macos.xml`][appcast-gold] and
[`appcast-anvil-stable-windows.xml`][appcast-win-gold].

> **Windows EdDSA blocker (v1, mac/AppImage/Android unblocked).** The
> `auto_updater` plugin vendors **WinSparkle 0.8.1, which predates EdDSA
> (added in 0.9.0)**, and the Dart layer exposes no Windows pubkey setter. Until
> the vendored WinSparkle is upgraded to ≥0.9.0 with the `EdDSAPub`/`EDDSA`
> resource (or the plugin is patched to call
> `win_sparkle_set_eddsa_public_key`), **Windows verification is not
> EdDSA-capable** and the Windows lane is blocked for GA. macOS uses
> `Info.plist` `SUPublicEDKey`; AppImage/Android use the compiled-in registry
> key directly.

### Staged rollout (deterministic, per-install)

```
bucket   = int(sha256(install_id + ":" + product).hexdigest()[:8], 16) % 100  # stable 0..99 (32-bit slice, no modulo bias)
eligible = not paused
           and bucket < rollout_pct
           and candidate.version  > current.version          # downgrade guard
           and candidate.version >= min_os_supported(client) # OS floor
```

Ramp by bumping `rollout_pct` (e.g. 10 → 50 → 100). **Pause instantly** by
setting `paused=true` / `rollout_pct=0` — the next check stops offering it.
Because Sparkle's built-in phased rollout is *time*-based only, the appcast
endpoint must gate on the client-sent `install_id`/`bucket` and render the item
in/out server-side (the `auto_updater` plugin sets the feed URL with query
params, so this works for mac/win too).

---

## 5. Distribution plane (R2 / S3 + CDN)

Immutable, predictable layout:

```
cdn.printdeck.app/
  {product}/{channel}/{version}/
    Anvil-1.4.0.dmg            Anvil-1.4.0.dmg.sig        (EdDSA)
    Anvil-1.4.0-setup.exe      …-setup.exe.sig
    Anvil-1.4.0.AppImage       …AppImage.zsync  …AppImage.sig
    anvil-direct-1.4.0.apk     …apk.sig
```

`cepheus-build` uploads here at release time. Optionally hand out short-lived
signed download URLs if we ever license-gate downloads. The
existing GitHub-Releases lane can stay on as a **public mirror / fallback feed**.

---

## 6. Supply bridge — new `cepheus-build` lane

Mirrors the existing env-gated, shared-script pattern exactly (so it's an
extension, not a new paradigm). Per-product:

```toml
[stores.update_publish]
enabled = true
cwd = "."
required_env = ["CL_UPDATE_ED25519_PRIVATE_KEY", "CL_UPDATE_PUBLISH_TOKEN",
                "R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY",
                "R2_BUCKET"]
commands = [
  "bash \"$CBUILD_TOOL_ROOT/scripts/publish-update-feed.sh\" \
     --product deckhand --channel \"$CBUILD_CHANNEL\" \
     --version \"$CBUILD_VERSION\" --build \"$CBUILD_BUILD_NUMBER\" \
     packaging/macos/dist/*.dmg packaging/windows/dist/*.exe \
     packaging/linux/dist/*.AppImage packaging/android/dist/*.apk",
]
```

New shared scripts (alongside `sign-linux-gpg.sh` / `sign-windows.ps1`):

- `scripts/sign-update-eddsa.sh` — EdDSA-sign one artifact (env-gated; no key →
  warn + skip, same contract as the other signers).
- `scripts/publish-update-feed.sh` — for each artifact: sha256 + EdDSA sign →
  upload to R2 → `POST /api/v1/updates/admin/releases`. (Fallback mode: render `appcast.xml`
  and attach to the GH release when the backend isn't reachable.)

**Channel derivation:** `$CBUILD_CHANNEL` from the release trigger — release tag
→ `stable`, pre-release/`beta` branch → `beta`, scheduled CI → `nightly` (its own
R2 prefix + channel row). Add `CL_UPDATE_*` / `R2_*` as optional secrets in the
reusable workflow (never echoed), same as the signing secrets today.

---

## 7. Client package — `cl_updater`

A **new standalone Flutter package** (own repo), consumed like `forge` is. Kept
UI-agnostic so both forge apps and Deckhand (`deckhand_ui`) can use it; it
*depends on* nothing app-specific.

```
cl_updater/
  lib/
    update_controller.dart     # headless: config + state machine
    adapters/
      mac_windows.dart         # → auto_updater (Sparkle/WinSparkle)
      linux_packaged.dart      # detect deb/rpm/flatpak → nudge only
      appimage.dart            # zsync + EdDSA verify + atomic swap
      android_sideload.dart    # PackageInstaller (direct flavor only)
    ui/                        # optional, theme-able banner + settings panel
```

- **`UpdateController`** (headless) — config: product slug, channel (from prefs),
  compiled pubkeys, control-plane base URL, current version (`package_info`),
  anonymous `install_id`. Emits a state stream:
  `idle · checking · available · downloading · readyToInstall · upToDate · mustUpdate · error`.
  Methods: `checkNow()`, `setChannel()`, `installNow()`.
- **Adapters** behind one interface; selected at runtime by detecting install
  form (`$APPIMAGE` set? `/.flatpak-info` present? dpkg/rpm owns the binary
  path?). mac/win just *configure* `auto_updater` (feed URL with params) and
  listen — Sparkle/WinSparkle do download+apply, and "install on quit" maps to
  Sparkle's automatic-download + install-on-quit setting.
- **UI** — ships optional, theme-able widgets (update banner + a settings panel
  with channel selector, "check now", release notes). Apps can ignore them and
  render their own from controller state. Forge apps get a forge-styled variant;
  Deckhand uses a `deckhand_ui`-styled one.
- **`install_id`** — generated once, stored in app-support dir, anonymous; used
  for rollout bucketing + telemetry. Telemetry is opt-out and documented.

---

## 8. Channels

| Channel | Source | Audience | R2 prefix |
|---|---|---|---|
| `stable` | release tag `v…` | everyone (default) | `…/stable/…` |
| `beta` | pre-release / `beta` branch | opt-in testers | `…/beta/…` |
| `nightly` | scheduled CI | internal dogfood | `…/nightly/…` |

Channel is a client preference (settings panel) that selects which feed/`/check`
channel is queried. Nightly is a scheduled `cepheus-build` run publishing to the
nightly prefix + channel row.

---

## 9. Android non-store track

Two product flavors:

- **`play`** — Play Store install; uses Play's own update (or `in_app_update`).
- **`direct`** — sideload; self-updates via `cl_updater`'s `android_sideload`
  adapter.

Both flavors **must share the same signing key** so a direct APK can install over
a prior one. Flow: `/check` → download APK to cache → verify the **pinned signer
cert** + sha256 + EdDSA → `FileProvider` URI → `PackageInstaller` (user grants
"install unknown apps" once; `REQUEST_INSTALL_PACKAGES` in the manifest).

This is why `[targets.android]` (currently `enabled=false`) gains a `direct`
flavor target, an `apk` artifact uploaded to R2, and a feed entry.

---

## 10. Fleet / Deckhand note

Deckhand can run in a managed/printer context (ties to the foundry
identity / `OsContract` work). Leave a policy hook in `cl_updater`:
config can pin a channel and switch UX to **silent/forced** with no user
prompt, driven by an MDM-style/`OsContract` override. Out of scope for v1, but
the controller's config object should make it a later flag, not a rewrite.

---

## 11. Phased delivery

| Phase | Scope | Done when |
|---|---|---|
| **0 — keys & contracts** | Generate EdDSA keypair (CI secret + registry pubkey); freeze appcast / `/check` / release-record schemas + registry; pick R2 bucket + layout. **DONE — see [Phase 0 — frozen contracts](#phase-0--frozen-contracts).** | Schemas + key tooling exist; no user-visible change |
| **1 — supply bridge** | `update_publish` lane + `sign-update-eddsa.sh` + `publish-update-feed.sh` + R2 upload | One product's release lands in a staging feed by hand |
| **2 — control plane** | `pd-updates` endpoints + `releases` table + rollout/pause/min-version, behind the gateway; deploy via existing flow | `/appcast.xml` + `/check` serve a real release with rollout honored |
| **3 — client (mac+win)** | `cl_updater` + `auto_updater` adapter; wire **one pilot app** (suggest Colorwake or Anvil — pure forge UI + Rust native bundle) | Pilot self-updates on quit on mac & win; channel selector works |
| **4 — Linux + all apps** | packaged-detect + AppImage adapter; roll to Deckhand + Printdeck | All four updating on mac/win/linux |
| **5 — Android direct** | sideload adapter + `direct` flavor + feed entries (when you do non-store Android) | Direct APK self-updates |
| **6 — polish** | rollout/telemetry dashboard, min-version enforcement drill, key-rotation drill | Ops can ramp/pause/rotate confidently |

GitHub-Releases-hosted appcast can serve as a **Phase-1 fallback** so client work
can start before the backend lands.

---

## 12. Risks & open questions

- **Windows signing first.** WinSparkle re-running an unsigned `.exe` trips
  SmartScreen on every update. Land **Azure Trusted Signing** before Windows
  auto-update GA.
- **Closed loops stay closed.** Never self-update Flatpak or MS-Store/App-Store
  installs — detect and defer to their stores.
- **Atomic apply + rollback** (AppImage/Android): verify-before-replace; keep the
  old binary until the new one launches once.
- **Key loss = no updates.** Back up the Ed25519 seed; rotate via the OLD-key-
  signed bridge that embeds the NEW pubkey (Sparkle trusts one key at a time — it
  is *not* a "trust two keys" model). Never rotate the EdDSA key and the OS
  code-signing cert in the same update.
- **Privacy.** `install_id` is anonymous + rotatable; telemetry opt-out;
  document it (matches the licensing/identity posture).

**Open choices:** R2 vs S3+CloudFront; `pd-updates` as its own service vs a
`pd-core` module; exact channel→branch/tag mapping; which app pilots Phase 3.

### Envelope authentication — accepted risk (Phase 0/1)

The **artifact** is EdDSA-signed and the client verifies it before applying (§3).
The **decision envelope** the control plane returns — the `/check` fields
`update`, `mandatory`, `min_supported_version`, `reason` (and the equivalent
appcast `<item>` gating) — is **not** itself signed in v1; it is trusted because
it arrives over **TLS (cert-pinned to `printdeck.app`)**. A network attacker who
could break that TLS could suppress or alter a decision (e.g. hide a mandatory
update or spoof `min_supported_version`), but could **not** forge a malicious
binary, because the EdDSA artifact signature still has to verify against the
compiled-in public key. This is **the same posture as Sparkle's classic
unsigned-appcast model** and is an **accepted risk for v1**.

Forward-compatible hook: `printdeck.update-check-response/1` already carries
optional, nullable `envelope_signature` (base64 raw 64-byte Ed25519 over a
canonical serialization of the security-critical fields) and `expires_at`
(anti-replay freshness bound). Both stay `null` until envelope/feed signing
ships; turning it on is then an additive change, not a contract break.

---

## Phase 0 — frozen contracts

Phase 0 ("keys & contracts") is **done**. The data contracts that bind the
supply lane, the control plane, and the clients are frozen as **Update Contracts
v1** and live in the `printdeck-contracts` repo under `ecosystem/` (validated by
its `validate.ps1`). §3 and §4 above are narrative; these files are normative.

**Schemas + XSD** (`printdeck-contracts/ecosystem/schemas/`):

- [`printdeck.release-record.v1.json`][rr] — canonical release record; doubles
  as the `POST /api/v1/updates/admin/releases` body and the `releases` row model.
- [`printdeck.update-check-response.v1.json`][ucr] — the `GET /check` decision
  for AppImage + Android.
- [`printdeck.update-event.v1.json`][ue] — the `POST /events` telemetry contract.
- [`printdeck.appcast.v1.xsd`][xsd] — the Sparkle/WinSparkle appcast render
  contract (per-platform feeds; verbatim sparkle namespace).

**Golden fixtures** (`printdeck-contracts/ecosystem/goldens/distribution/`):

- [`release-record-anvil-macos.json`][rr-gold] · `release-record-anvil-windows.json`
- [`update-check-appimage-available.json`][ucr-appimg] · [`update-check-android-current.json`][ucr-android]
- [`update-event-applied.json`][ue-gold]
- [`appcast-anvil-stable-macos.xml`][appcast-gold] · [`appcast-anvil-stable-windows.xml`][appcast-win-gold]
  (renderings of the release-record goldens; the validator asserts the field
  mapping field-by-field, including the Windows arch->sparkle:os token)

**Registry / trust anchor**
([`registry/update-distribution.json`][reg]) — the canonical
channel/platform/arch/signature_target/flavor/telemetry/reason enums (source for
the generated client constants), the release-record required-field list, the
appcast policy, and the Ed25519 `signing_keys` (`current` + `next` for dual-key
bridge rotation). The live public key is a placeholder there until keygen is run.

**Key tooling** (`cepheus-build/scripts/`, pynacl, house env-gating):

- [`cl-update-keygen.sh`](../scripts/cl-update-keygen.sh) — human-run; generates
  the Ed25519 keypair (base64 32-byte seed + pubkey), prints the seed once for CI
  capture. Not wired into any lane.
- [`sign-update-eddsa.sh`](../scripts/sign-update-eddsa.sh) — ENV-gated detached
  signer (raw file bytes → base64 64-byte sig in `<file>.sig`).
- [`verify-update-eddsa.sh`](../scripts/verify-update-eddsa.sh) — CI verify gate
  before publish.
- [`publish-update-feed.sh`](../scripts/publish-update-feed.sh) — the Phase-1
  supply bridge (sha256 + sign → R2 → `POST /api/v1/updates/admin/releases`), wired as the
  `[stores.update_publish]` lane (`enabled=false`) in each product TOML.

[rr]: ../../printdeck-contracts/ecosystem/schemas/printdeck.release-record.v1.json
[ucr]: ../../printdeck-contracts/ecosystem/schemas/printdeck.update-check-response.v1.json
[xsd]: ../../printdeck-contracts/ecosystem/schemas/printdeck.appcast.v1.xsd
[reg]: ../../printdeck-contracts/ecosystem/registry/update-distribution.json
[rr-gold]: ../../printdeck-contracts/ecosystem/goldens/distribution/release-record-anvil-macos.json
[ucr-appimg]: ../../printdeck-contracts/ecosystem/goldens/distribution/update-check-appimage-available.json
[ucr-android]: ../../printdeck-contracts/ecosystem/goldens/distribution/update-check-android-current.json
[appcast-gold]: ../../printdeck-contracts/ecosystem/goldens/distribution/appcast-anvil-stable-macos.xml
[appcast-win-gold]: ../../printdeck-contracts/ecosystem/goldens/distribution/appcast-anvil-stable-windows.xml
[ue]: ../../printdeck-contracts/ecosystem/schemas/printdeck.update-event.v1.json
[ue-gold]: ../../printdeck-contracts/ecosystem/goldens/distribution/update-event-applied.json
