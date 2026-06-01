# buildkit — shared Rust→Flutter build kit

Shared, parameterized build scripts for the Cepheus Labs apps that ship a
**Flutter UI over a Rust `cdylib`** (Anvil, Colorwake Studio). It de-duplicates
the per-platform "build the Rust core and embed it into the Flutter bundle"
machinery that was, until now, near-verbatim-copied into each app:

- macOS / iOS Xcode "Build Rust Core" run-script phases (lipo → versioned/flat
  `.framework` → `@rpath` → codesign),
- the load-bearing rustup/`RUSTC` toolchain-resolution workaround,
- the Linux/Windows CMake `*_rust_core` build+install target,
- the macOS Developer-ID (DMG/notarize) and App Store (`.pkg`) packaging
  scripts.

Each consumer keeps only a tiny **shim** that supplies its crate/app identity;
the body lives here once. The shared scripts are invoked from each app's
checkout of this repo at `shared/cepheus-build` (Xcode/CMake) or from the
product TOMLs via `$CBUILD_TOOL_ROOT/buildkit/...` (the build CLI).

> ## ⚠️ NOT BUILD-VERIFIED IN THIS ENVIRONMENT — verify on macOS + Windows
>
> These are **codesigning / framework-embed / iOS / Windows** scripts. They
> **cannot be functionally verified** where they were authored: there were no
> signing certs, no Xcode archive, and no Windows host available. The bar met
> here is **correctness-by-construction** (mirrored byte-for-byte against the
> apps' working originals) **+ a clean `shellcheck`** — *not* a green build.
>
> **Before merging the adoption commits you MUST, on real hardware:**
> - **macOS:** `flutter build macos` for Anvil *and* Colorwake, launch each, and
>   exercise a real Rust call (Anvil: slice; Colorwake: process an image) — a
>   bad embed is a black screen / `DynamicLibrary.open()` throw. Then run one
>   `package-macos-developerid.sh` (sign + DMG + notarize) per app, and verify
>   the App Store `.pkg` path if you ship to MAS.
> - **iOS:** a signed device archive + a symbolicated TestFlight crash for
>   Colorwake (the dSYM step is why the iOS script is a *merge*, not a copy).
> - **Linux:** `flutter build linux` for both (Colorwake's debug build now uses
>   the **dev** cargo profile — a deliberate change; confirm it still runs).
> - **Windows:** `flutter build windows` for both — including Colorwake, which
>   **gains** a CMake rust target it never had (it used a PS1 `Copy-Item`).
>
> Treat this kit as authored-and-reviewed, **pending** that build/sign/notarize
> pass on the user's machines.

---

## File tree

```
buildkit/
  lib/rustup-resolve.sh              # sourced: resolve cargo/rustc via rustup, export RUSTC
  macos/embed-rust-macos.sh          # parameterized macOS "Build Rust Core" body (versioned .framework)
  macos/embed-rust-ios.sh            # parameterized iOS body (flat .framework + dSYM + min-OS + device/sim signing)
  cmake/CepheusRustCore.cmake        # cepheus_add_rust_core(CRATE LIB_BASENAME RUST_ROOT BINARY_NAME)
  package/package-macos-developerid.sh   # Developer ID: sign + DMG + notarize + staple
  package/package-macos-appstore.sh      # MAS: sign + .pkg + optional upload
  README.md                          # this file
```

The shell scripts pass `shellcheck` clean (the only remaining diagnostics are
two intentional, documented info-level suppressions: `SC1091` for the
runtime-resolved `source`, and `SC2153` for Xcode's `ARCHS` env var).

---

## The one-way rule

Every script here takes the **crate / app identity as a parameter** (env var or
CMake arg) and **never names an engine crate** (`pd-*`, `colorwake_*`). Shared
build code depends on nothing app-specific; apps depend on the kit. `lib/`,
`macos/`, `cmake/`, and `package/` were all audited for this — they are pure
plumbing keyed off `CEPHEUS_*` / function arguments.

---

## Env-var contract

### The 6-var embed interface (macOS + iOS shims set these)

| Var | Required | Meaning | Anvil | Colorwake |
|-----|----------|---------|-------|-----------|
| `CEPHEUS_CRATE` | yes | cargo package to `-p` build | `pd-ffi` | `colorwake_native` |
| `CEPHEUS_LIB_NAME` | yes | dylib base name → `lib<NAME>.dylib` | `pd_ffi` | `colorwake_native` |
| `CEPHEUS_FRAMEWORK_NAME` | yes | `.framework` + binary (+ dSYM) name | `pd_ffi` | `colorwake_native` |
| `CEPHEUS_BUNDLE_ID` | yes¹ | the **app** id (part of the 6-var block; not consumed by the embed scripts today — see note) | `com.cepheuslabs.anvil` | `com.cepheuslabs.colorwakestudio` |
| `CEPHEUS_FRAMEWORK_BUNDLE_ID` | yes | the **framework's** `CFBundleIdentifier` (distinct from the app id) | `com.cepheuslabs.anvil.pd-ffi` | `com.cepheuslabs.colorwakestudio.colorwake-native` |
| `CEPHEUS_RUST_ROOT` | yes | abs path to the cargo workspace root (dir holding `Cargo.toml`); the shim derives it from `SRCROOT` | `${SRCROOT}/../..` | `${SRCROOT}/../../..` |

¹ `CEPHEUS_BUNDLE_ID` is carried in the shim's variable block so the *same* block
documents the full identity and is future-proof, but neither embed script reads
it today (the framework carries `CEPHEUS_FRAMEWORK_BUNDLE_ID`; the app id is set
by Xcode/Flutter project settings). Set it anyway for clarity; it is accepted
and ignored.

### iOS-only override

| Var | Required | Default | Meaning |
|-----|----------|---------|---------|
| `CEPHEUS_IOS_MIN_OS` | no | `${IPHONEOS_DEPLOYMENT_TARGET:-13.0}` | `MinimumOSVersion` written into the framework `Info.plist`. **Colorwake passes `18.0`** (carrying what its checked-in `colorwake_native_framework_Info.plist` used to hardcode); Anvil omits it and floats with the Xcode deployment target. |

### Xcode-provided environment (the shim never sets these)

`CONFIGURATION`, `ARCHS`, `PLATFORM_NAME` (iOS), `BUILT_PRODUCTS_DIR`,
`FRAMEWORKS_FOLDER_PATH`, `IPHONEOS_DEPLOYMENT_TARGET` (iOS),
`DWARF_DSYM_FOLDER_PATH` (iOS, gates the dSYM step),
`EXPANDED_CODE_SIGN_IDENTITY`, `CODE_SIGNING_ALLOWED`. The macOS/iOS scripts
read these directly from the Xcode build environment.

### CMake helper arguments

`cepheus_add_rust_core(CRATE <c> LIB_BASENAME <b> RUST_ROOT <p> BINARY_NAME <n>)`
— all four required. It sets **`CEPHEUS_RUST_CORE_LIB`** in the calling scope
(the resolved `.so`/`.dll` path) for the caller's `install(FILES ...)`.

### Packaging-script env

The packaging scripts are parameterized by `CEPHEUS_*` **and** keep working
with the existing `<PREFIX>_*` knobs (`ANVIL_*` / `COLORWAKE_*`) so the product
TOMLs barely change. Set `CEPHEUS_ENV_PREFIX=ANVIL|COLORWAKE` and the
version/notary/skip/identity knobs below additionally read `<PREFIX>_*`.

| Var | Required | Default | Used by |
|-----|----------|---------|---------|
| `CEPHEUS_APP_PATH` | yes | — | both — abs path to the built `.app` |
| `CEPHEUS_APP_DIR` | yes | — | both — dir to run `flutter build macos` in |
| `CEPHEUS_ENTITLEMENTS` | yes | — | both — abs path to the app's entitlements (**stays per-app**, never baked) |
| `CEPHEUS_VOLNAME` | yes (devid) | — | DMG volume name |
| `CEPHEUS_DMG_NAME` | yes (devid) | — | output DMG filename |
| `CEPHEUS_PKG_NAME` | yes (appstore) | — | output `.pkg` filename |
| `CEPHEUS_MAS_PROFILE` (or `<PREFIX>_MAS_PROFILE`) | yes (appstore) | — | `.provisionprofile` path |
| `CEPHEUS_ENV_PREFIX` | no | — | enables `<PREFIX>_*` fallback for the knobs below |
| `CEPHEUS_VERSION` (or `<PREFIX>_VERSION`) | no | `0.0.0` | flutter `--build-name` |
| `CEPHEUS_BUILD_NUMBER` (or `<PREFIX>_BUILD_NUMBER`) | no | `1` | flutter `--build-number` |
| `CEPHEUS_DIST_DIR` | no | `<repo>/dist/macos` | output dir |
| `CEPHEUS_DEVID_IDENTITY` (or `<PREFIX>_DEVID_IDENTITY`) | no | `Developer ID Application: Cepheus Labs, LLC (J2W5M4CY69)` | devid signing identity |
| `CEPHEUS_NOTARY_PROFILE` (or `<PREFIX>_NOTARY_PROFILE`) | no | `AC_NOTARY` | notarytool keychain profile |
| `CEPHEUS_SKIP_NOTARIZE` (or `<PREFIX>_SKIP_NOTARIZE`) | no | `0` | `1` → sign + DMG only |
| `CEPHEUS_MAS_APP_IDENTITY` (or `<PREFIX>_…`) | no | `Apple Distribution: Cepheus Labs, LLC (J2W5M4CY69)` | MAS app identity |
| `CEPHEUS_MAS_INSTALLER_IDENTITY` (or `<PREFIX>_…`) | no | `3rd Party Mac Developer Installer: Cepheus Labs, LLC (J2W5M4CY69)` | MAS installer identity |
| `CEPHEUS_MAS_UPLOAD` (or `<PREFIX>_MAS_UPLOAD`) | no | `0` | `1` → upload `.pkg` after build |
| `CEPHEUS_ASC_APPLE_ID` / `CEPHEUS_ASC_PASSWORD` | upload only | — | App Store Connect upload creds |

The **org cert identity literals are baked as defaults** (they are byte-identical
across apps), overridable per the table. The **`*.entitlements` are deliberately
NOT baked** — Anvil's `DeveloperID.entitlements` carries
`disable-library-validation` (it dlopens native plugins) while Colorwake's omits
it, and file-access keys differ; each app passes its own via
`CEPHEUS_ENTITLEMENTS`.

---

## Per-app application guide

Both apps already vendor this repo at `shared/cepheus-build`, so the buildkit is
reachable at `shared/cepheus-build/buildkit/...`. The depth of the `..` hops
differs because Anvil's Flutter app is at `app/` (repo-root workspace) while
Colorwake's is at `apps/colorwake_studio/` (one level deeper).

### Anvil

**`app/macos/rust_core_build.sh`** — replace the whole file with this shim
(`SRCROOT` = `app/macos`, so `../..` is the repo root and the buildkit is two
hops up then into the submodule):

```sh
#!/bin/sh
set -eu
export CEPHEUS_CRATE="pd-ffi"
export CEPHEUS_LIB_NAME="pd_ffi"
export CEPHEUS_FRAMEWORK_NAME="pd_ffi"
export CEPHEUS_BUNDLE_ID="com.cepheuslabs.anvil"
export CEPHEUS_FRAMEWORK_BUNDLE_ID="com.cepheuslabs.anvil.pd-ffi"
export CEPHEUS_RUST_ROOT="${SRCROOT}/../.."
exec "${SRCROOT}/../../shared/cepheus-build/buildkit/macos/embed-rust-macos.sh"
```

**`app/ios/rust_core_build.sh`** — same identity; iOS body; **no**
`CEPHEUS_IOS_MIN_OS` (Anvil floats with the Xcode deployment target):

```sh
#!/bin/sh
set -eu
export CEPHEUS_CRATE="pd-ffi"
export CEPHEUS_LIB_NAME="pd_ffi"
export CEPHEUS_FRAMEWORK_NAME="pd_ffi"
export CEPHEUS_BUNDLE_ID="com.cepheuslabs.anvil"
export CEPHEUS_FRAMEWORK_BUNDLE_ID="com.cepheuslabs.anvil.pd-ffi"
export CEPHEUS_RUST_ROOT="${SRCROOT}/../.."
exec "${SRCROOT}/../../shared/cepheus-build/buildkit/macos/embed-rust-ios.sh"
```

**`app/linux/CMakeLists.txt`** — replace the inline rust block (the
`ANVIL_RUST_ROOT`/profile/`find_program(cargo)`/`add_custom_target(anvil_rust_core)`
section) with the include + call, and point the existing
`install(FILES "${ANVIL_RUST_LIB}" ...)` at `${CEPHEUS_RUST_CORE_LIB}`:

```cmake
include("${CMAKE_CURRENT_SOURCE_DIR}/../../shared/cepheus-build/buildkit/cmake/CepheusRustCore.cmake")
cepheus_add_rust_core(
  CRATE        pd-ffi
  LIB_BASENAME pd_ffi
  RUST_ROOT    "${CMAKE_CURRENT_SOURCE_DIR}/../.."
  BINARY_NAME  "${BINARY_NAME}"
)
# ... later, in the install section:
install(FILES "${CEPHEUS_RUST_CORE_LIB}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
```

**`app/windows/CMakeLists.txt`** — same include + call (the helper branches
`WIN32` to the `.dll`); point `install(FILES "${ANVIL_RUST_DLL}" ...)` at
`${CEPHEUS_RUST_CORE_LIB}` (on Windows `INSTALL_BUNDLE_LIB_DIR` is the exe dir).

### Colorwake Studio

**`apps/colorwake_studio/macos/build_rust_native_core.sh`** — replace with this
shim (`SRCROOT` = `apps/colorwake_studio/macos`, so `../../..` is the repo
root — note the **extra hop** vs Anvil):

```sh
#!/bin/sh
set -eu
export CEPHEUS_CRATE="colorwake_native"
export CEPHEUS_LIB_NAME="colorwake_native"
export CEPHEUS_FRAMEWORK_NAME="colorwake_native"
export CEPHEUS_BUNDLE_ID="com.cepheuslabs.colorwakestudio"
export CEPHEUS_FRAMEWORK_BUNDLE_ID="com.cepheuslabs.colorwakestudio.colorwake-native"
export CEPHEUS_RUST_ROOT="${SRCROOT}/../../.."
exec "${SRCROOT}/../../../shared/cepheus-build/buildkit/macos/embed-rust-macos.sh"
```

**`apps/colorwake_studio/ios/build_rust_native_core.sh`** — same identity; iOS
body; **`CEPHEUS_IOS_MIN_OS="18.0"`** (carries the floor the checked-in plist
used to hardcode):

```sh
#!/bin/sh
set -eu
export CEPHEUS_CRATE="colorwake_native"
export CEPHEUS_LIB_NAME="colorwake_native"
export CEPHEUS_FRAMEWORK_NAME="colorwake_native"
export CEPHEUS_BUNDLE_ID="com.cepheuslabs.colorwakestudio"
export CEPHEUS_FRAMEWORK_BUNDLE_ID="com.cepheuslabs.colorwakestudio.colorwake-native"
export CEPHEUS_RUST_ROOT="${SRCROOT}/../../.."
export CEPHEUS_IOS_MIN_OS="18.0"
exec "${SRCROOT}/../../../shared/cepheus-build/buildkit/macos/embed-rust-ios.sh"
```

> Note: Colorwake's current iOS script uses `PROJECT_DIR`; the shared script and
> these shims standardize on `SRCROOT` (both point at the platform dir under
> Xcode). If the Runner target's run-script previously referenced `PROJECT_DIR`,
> the shim above replaces it.

**`apps/colorwake_studio/linux/CMakeLists.txt`** — replace the inline
`colorwake_native_rust` block with the include + call (this *also* gives
Colorwake's Linux build the Debug→dev profile mapping it lacked), and point its
`install(FILES "${COLORWAKE_NATIVE_LIB}" ...)` at `${CEPHEUS_RUST_CORE_LIB}`:

```cmake
include("${CMAKE_CURRENT_SOURCE_DIR}/../../../shared/cepheus-build/buildkit/cmake/CepheusRustCore.cmake")
cepheus_add_rust_core(
  CRATE        colorwake_native
  LIB_BASENAME colorwake_native
  RUST_ROOT    "${CMAKE_CURRENT_SOURCE_DIR}/../../.."
  BINARY_NAME  "${BINARY_NAME}"
)
install(FILES "${CEPHEUS_RUST_CORE_LIB}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
```

**`apps/colorwake_studio/windows/CMakeLists.txt`** — Colorwake's Windows
CMakeLists has **no rust block today** (it copies the DLL from
`scripts/build-windows.ps1`). **Add** the include + call + install so the build
itself produces and stages the DLL:

```cmake
include("${CMAKE_CURRENT_SOURCE_DIR}/../../../shared/cepheus-build/buildkit/cmake/CepheusRustCore.cmake")
cepheus_add_rust_core(
  CRATE        colorwake_native
  LIB_BASENAME colorwake_native
  RUST_ROOT    "${CMAKE_CURRENT_SOURCE_DIR}/../../.."
  BINARY_NAME  "${BINARY_NAME}"
)
install(FILES "${CEPHEUS_RUST_CORE_LIB}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
```

### `products/*.toml` edits (this repo)

The packaging lanes change from invoking each app's local
`scripts/package-macos-*.sh` to invoking the shared script with the new env. The
`<PREFIX>_*` back-compat means the change is small.

**`products/anvil.toml` — `[targets.macos-dmg]`:**

```toml
[targets.macos-dmg]
hosts = ["macos"]
cwd = "."
commands = [
  "CEPHEUS_ENV_PREFIX=ANVIL CEPHEUS_APP_PATH=\"$CBUILD_REPO_ROOT/app/build/macos/Build/Products/Release/anvil.app\" CEPHEUS_APP_DIR=\"$CBUILD_APP_DIR\" CEPHEUS_ENTITLEMENTS=\"$CBUILD_APP_DIR/macos/Runner/DeveloperID.entitlements\" CEPHEUS_VOLNAME=\"Anvil\" CEPHEUS_DMG_NAME=\"Anvil-$CBUILD_VERSION.dmg\" ANVIL_VERSION=\"$CBUILD_VERSION\" ANVIL_BUILD_NUMBER=\"$CBUILD_BUILD_NUMBER\" bash \"$CBUILD_TOOL_ROOT/buildkit/package/package-macos-developerid.sh\"",
]
artifacts = ["dist/macos/Anvil-*.dmg"]
tools = ["cargo", "flutter", "xcodebuild", "pod", "codesign"]
```

The Anvil macOS *build* lane (`[targets.macos]`) and the Windows/Linux lanes are
unchanged (they run `cargo build` + `flutter build`; the CMake helper handles the
desktop rust core). The MAS `.pkg` lane, if/when added, points at
`buildkit/package/package-macos-appstore.sh` with `CEPHEUS_PKG_NAME` +
`CEPHEUS_MAS_PROFILE` (and `CEPHEUS_ENTITLEMENTS` → `AppStore.entitlements`).

**`products/colorwake-studio.toml`:**

- `[targets.macos-dmg]` — same shape as Anvil's, with
  `CEPHEUS_ENV_PREFIX=COLORWAKE`, app path
  `…/Release/colorwake_studio.app`, `CEPHEUS_VOLNAME="Colorwake Studio"`,
  `CEPHEUS_DMG_NAME="ColorwakeStudio-$CBUILD_VERSION.dmg"`, entitlements
  `…/macos/Runner/DeveloperID.entitlements`, and
  `COLORWAKE_VERSION`/`COLORWAKE_BUILD_NUMBER`.
- `[targets.macos]` — **delete the inline bare-dylib embed block** (the
  `mkdir`/`lipo`/`install_name_tool`/`codesign --force --sign -` /
  `codesign --deep` lines, currently 5 commands after the flutter build). Those
  produce an **unsigned bare dylib** that the packaging signer (which globs
  `*.framework`) never re-signs; the Xcode "Build Rust Native Core" phase (now
  the shared shim) already stages a **signed `.framework`**. Reduce the lane to
  the rustup-target-add + per-arch `cargo build` + `flutter build macos` lines.
- `[targets.windows]` and `[targets.windows-msix]` — **drop the inline
  `Copy-Item … colorwake_native.dll` step** from each `pwsh` one-liner; the new
  Windows CMake rust target builds and installs the DLL during `flutter build
  windows`. (Keep the `cargo build`/`flutter build`/`dart run msix:create`
  parts.)

### Files to DELETE per app (after the shims/CMake/TOML land and build green)

**Anvil:**
- `scripts/package-macos-developerid.sh` — superseded by
  `buildkit/package/package-macos-developerid.sh`.
- `scripts/package-macos-appstore.sh` — superseded by
  `buildkit/package/package-macos-appstore.sh`.

**Colorwake Studio:**
- `scripts/package-macos-developerid.sh` — superseded by the shared script.
- `scripts/package-macos-appstore.sh` — superseded by the shared script.
- `scripts/build-macos.sh` — its universal-dylib embed is now the Xcode shared
  phase (and it emitted the same **unsigned bare dylib** + `codesign --deep`
  that distribution discourages).
- the inline **bare-dylib embed block** in `products/colorwake-studio.toml`
  `[targets.macos]` (listed above).
- the **`Copy-Item … colorwake_native.dll`** lines in
  `scripts/build-windows.ps1` and in the `windows`/`windows-msix` TOML lanes —
  the Windows CMake rust target replaces them. (`scripts/build-windows.ps1`
  otherwise just runs `cargo build` + `flutter build windows`; once the
  Copy-Item is gone it is a thin convenience wrapper — keep or delete per the
  app's preference.)
- `apps/colorwake_studio/ios/Runner/colorwake_native_framework_Info.plist` —
  **only after** the iOS shim sets `CEPHEUS_IOS_MIN_OS="18.0"`. The shared iOS
  script generates the framework `Info.plist` itself (with the same
  `MinimumOSVersion 18.0`), so the checked-in copy is no longer read. Do **not**
  delete it until the shim carries the 18.0 floor, or you regress the minimum-OS
  guarantee.

> **Stays per-app — do not delete or absorb:**
> - all `macos/Runner/*.entitlements` (`DeveloperID`/`AppStore`): library-validation
>   and file-access keys diverge by design (Anvil dlopens plugins, Colorwake
>   does not).
> - `anvil/.cargo/config.toml` (`LZMA_API_STATIC=1`) — **see liblzma note below.**
> - git/version stamping (`build.rs` SHA gate / `rev-list --count` build number):
>   different value, layer, and consumer in each app; not duplication.

---

## liblzma static-link stays in `anvil/.cargo/config.toml`

Anvil force-statically-links liblzma via `anvil/.cargo/config.toml`
(`[env] LZMA_API_STATIC = "1"`). `pd-ffi` pulls liblzma transitively
(`xz2 → … → pd-import/pd-mesh`); without the static link, `lzma-sys` links the
Homebrew `liblzma.5.dylib` dynamically, which is not bundled and is blocked at
dlopen on the sandboxed macOS build. **This is Anvil-specific and stays where it
is** — Colorwake has no `.cargo/` and no analogous static-link need. The
buildkit does **not** touch `.cargo/config.toml`; it only runs `cargo build`,
which honors the app's own `.cargo/config.toml`.

---

## What was merged for iOS (and why it is not a plain copy)

`embed-rust-ios.sh` is a deliberate **merge** of the two apps' iOS scripts, per
the corrected decision in `shared-extraction-plan.md` §2.1:

- **toolchain + multi-arch lipo** from Anvil (it pins cargo **and** rustc via
  `rustup which` + exported `RUSTC`; Colorwake used the weaker
  `rustup run stable`, which can pick up a Homebrew rustc lacking the
  cross-target std),
- **dSYM generation** from Colorwake (gated on `DWARF_DSYM_FOLDER_PATH`, dSYM
  basename = `CEPHEUS_FRAMEWORK_NAME`) — Anvil has no dSYM step, and dropping it
  would regress Colorwake's TestFlight crash symbolication,
- **`CEPHEUS_IOS_MIN_OS`** override (Colorwake passes `18.0`),
- **device-vs-simulator signing** from Colorwake (real identity → sign;
  simulator → ad-hoc sign; else skip).

Standardizing *down* to Anvil's iOS script would have been the build-kit
analogue of over-conservation — it would have silently regressed Colorwake.
