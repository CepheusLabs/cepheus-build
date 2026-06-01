#!/bin/sh
# embed-rust-macos.sh — shared, parameterized "Build Rust Core" run-script body
# for macOS. Builds an app's Rust cdylib for each Xcode arch, lipos the slices
# into a universal binary, stages it as a *versioned* `<name>.framework` inside
# the built app's Frameworks folder (the layout codesign requires on macOS,
# which does not use shallow bundles), rewrites its install name to @rpath, and
# signs it with the identity Xcode is using.
#
# This is the de-duplicated body of:
#   anvil/app/macos/rust_core_build.sh
#   colorwake-studio/apps/colorwake_studio/macos/build_rust_native_core.sh
# which were byte-identical apart from the crate name, framework name, and
# framework CFBundleIdentifier. Each app's Xcode phase becomes a ~3-line shim
# that exports the CEPHEUS_* vars below and execs this script (see the buildkit
# README for the exact per-app shims).
#
# ── Caller-supplied interface (the embed contract) ──────────────────────────
#   CEPHEUS_CRATE                cargo package to build (e.g. pd-ffi)            [required]
#   CEPHEUS_LIB_NAME             dylib base name without lib/.dylib             [required]
#                                  (e.g. pd_ffi -> target/.../libpd_ffi.dylib)
#   CEPHEUS_FRAMEWORK_NAME       .framework + binary name (e.g. pd_ffi)         [required]
#   CEPHEUS_FRAMEWORK_BUNDLE_ID  the framework's CFBundleIdentifier — DISTINCT  [required]
#                                  from the app id (e.g. com.cepheuslabs.anvil.pd-ffi)
#   CEPHEUS_RUST_ROOT            abs path to the cargo workspace root holding    [required]
#                                  Cargo.toml (the app resolves this from SRCROOT)
#
# Note: CEPHEUS_BUNDLE_ID (the *app* id) is part of the shared 6-var embed
# interface but is not consumed on macOS — the framework carries its own
# CEPHEUS_FRAMEWORK_BUNDLE_ID. It is accepted/ignored here so the same shim
# variable block works across macOS and iOS.
#
# ── Xcode-provided environment (the caller never sets these) ────────────────
#   CONFIGURATION ARCHS BUILT_PRODUCTS_DIR FRAMEWORKS_FOLDER_PATH
#   EXPANDED_CODE_SIGN_IDENTITY CODE_SIGNING_ALLOWED
#
# The script names no crate itself — the crate is a parameter, preserving the
# one-way rule (shared build code never hardcodes an engine crate).
set -eu

: "${CEPHEUS_CRATE:?set CEPHEUS_CRATE to the cargo package to build}"
: "${CEPHEUS_LIB_NAME:?set CEPHEUS_LIB_NAME to the dylib base name (no lib/.dylib)}"
: "${CEPHEUS_FRAMEWORK_NAME:?set CEPHEUS_FRAMEWORK_NAME to the .framework base name}"
: "${CEPHEUS_FRAMEWORK_BUNDLE_ID:?set CEPHEUS_FRAMEWORK_BUNDLE_ID to the framework CFBundleIdentifier}"
: "${CEPHEUS_RUST_ROOT:?set CEPHEUS_RUST_ROOT to the cargo workspace root}"

RUST_ROOT="${CEPHEUS_RUST_ROOT}"

# Map the Xcode configuration to a cargo profile + target subdirectory.
case "${CONFIGURATION}" in
  Debug)
    CARGO_PROFILE="dev"
    TARGET_SUBDIR="debug"
    ;;
  *)
    # Release and Profile both build the optimized core.
    CARGO_PROFILE="release"
    TARGET_SUBDIR="release"
    ;;
esac

# Resolve cargo/rustc via rustup and export RUSTC (sets RUSTUP, CARGO; exits on
# failure). See lib/rustup-resolve.sh for why this is load-bearing — do NOT
# inline a bare `cargo` here. Resolved relative to this script's own location so
# the lib is found regardless of the caller's CWD.
SCRIPT_DIR="$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)"
# SC1091: the fragment is resolved at runtime via $SCRIPT_DIR; it cannot be
# statically followed from an arbitrary CWD (e.g. an Xcode build dir).
# shellcheck source=../lib/rustup-resolve.sh disable=SC1091
. "${SCRIPT_DIR}/../lib/rustup-resolve.sh"

# Build one slice per Xcode arch, then lipo them into a universal binary so the
# embedded core matches the (potentially universal) Flutter shell.
# SC2153: ARCHS is Xcode-provided environment (like CONFIGURATION), not a typo.
# shellcheck disable=SC2153
echo "==> Building ${CEPHEUS_CRATE} (${CARGO_PROFILE}) for arch(s): ${ARCHS}"
SLICES=""
for ARCH in ${ARCHS}; do
  case "${ARCH}" in
    arm64)  RUST_TARGET="aarch64-apple-darwin" ;;
    x86_64) RUST_TARGET="x86_64-apple-darwin" ;;
    *) echo "error: unsupported arch '${ARCH}'" >&2; exit 1 ;;
  esac

  # Ensure the per-arch std is present (idempotent, no-op once installed).
  if [ -n "${RUSTUP}" ]; then
    "${RUSTUP}" target add "${RUST_TARGET}" >/dev/null 2>&1 || true
  fi

  "${CARGO}" build \
    --profile "${CARGO_PROFILE}" \
    --target "${RUST_TARGET}" \
    --manifest-path "${RUST_ROOT}/Cargo.toml" \
    -p "${CEPHEUS_CRATE}"

  SLICES="${SLICES} ${RUST_ROOT}/target/${RUST_TARGET}/${TARGET_SUBDIR}/lib${CEPHEUS_LIB_NAME}.dylib"
done

# Stage the framework inside the built app's Frameworks folder. macOS does NOT
# use shallow bundles, so the framework must be *versioned* (Versions/A/...)
# with the canonical top-level symlinks — Xcode/codesign reject a flat layout
# with "expected Versions/Current/Resources/Info.plist since the platform does
# not use shallow bundles". (iOS, which is shallow, uses the flat layout in
# embed-rust-ios.sh instead.)
FRAMEWORK_DIR="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}/${CEPHEUS_FRAMEWORK_NAME}.framework"
rm -rf "${FRAMEWORK_DIR}"
mkdir -p "${FRAMEWORK_DIR}/Versions/A/Resources"

# shellcheck disable=SC2086
set -- ${SLICES}
if [ "$#" -gt 1 ]; then
  lipo -create "$@" -output "${FRAMEWORK_DIR}/Versions/A/${CEPHEUS_FRAMEWORK_NAME}"
else
  cp "$1" "${FRAMEWORK_DIR}/Versions/A/${CEPHEUS_FRAMEWORK_NAME}"
fi

# The cdylib's install name is its build path; rewrite it so dyld resolves the
# embedded copy through the runner's @rpath entries (the top-level
# ${CEPHEUS_FRAMEWORK_NAME} symlink below points at Versions/Current/...).
install_name_tool -id "@rpath/${CEPHEUS_FRAMEWORK_NAME}.framework/${CEPHEUS_FRAMEWORK_NAME}" \
  "${FRAMEWORK_DIR}/Versions/A/${CEPHEUS_FRAMEWORK_NAME}"

cat > "${FRAMEWORK_DIR}/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>${CEPHEUS_FRAMEWORK_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${CEPHEUS_FRAMEWORK_BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${CEPHEUS_FRAMEWORK_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
</dict>
</plist>
PLIST

# Canonical framework symlinks (relative, so the bundle stays relocatable).
ln -sfh A "${FRAMEWORK_DIR}/Versions/Current"
ln -sfh "Versions/Current/${CEPHEUS_FRAMEWORK_NAME}" "${FRAMEWORK_DIR}/${CEPHEUS_FRAMEWORK_NAME}"
ln -sfh Versions/Current/Resources "${FRAMEWORK_DIR}/Resources"

# Sign the framework *bundle* with the same identity Xcode is using (ad-hoc
# when none), matching how Flutter/CocoaPods sign embedded frameworks. The
# final app-level signature then seals this framework into the bundle; the
# distribution scripts re-sign it with the Developer ID / Apple Distribution
# identity inside-out before packaging.
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
  IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  codesign --force --sign "${IDENTITY}" --timestamp=none "${FRAMEWORK_DIR}"
fi

echo "==> Embedded ${CEPHEUS_FRAMEWORK_NAME}.framework into ${FRAMEWORKS_FOLDER_PATH}"
