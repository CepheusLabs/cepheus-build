#!/bin/sh
# embed-rust-ios.sh — shared, parameterized "Build Rust Core" run-script body
# for iOS. iOS analogue of embed-rust-macos.sh: it picks the Rust target from
# the active SDK (device vs simulator) + Xcode's ARCHS, builds the app's cdylib,
# lipos the slices, stages a *flat* `<name>.framework` (iOS uses shallow
# bundles) with an Info.plist carrying MinimumOSVersion, rewrites @rpath,
# generates a dSYM for crash symbolication, and signs.
#
# This is a deliberate MERGE of the two apps' iOS scripts, taking the better
# half of each (see shared-extraction-plan.md §2.1, "iOS template — merge,
# don't replace"):
#   * toolchain/plist skeleton + multi-arch lipo  <- anvil/app/ios/rust_core_build.sh
#       (Anvil pins cargo AND rustc via `rustup which`+RUSTC; Colorwake used the
#        weaker `rustup run stable`, which can miss the cross-target std.)
#   * dSYM generation (gated on DWARF_DSYM_FOLDER_PATH)  <- colorwake ios script
#       (Anvil has NO dSYM step; dropping it would regress Colorwake's
#        TestFlight crash symbolication — so it is parameterized in, not out.)
#   * MinimumOSVersion override (CEPHEUS_IOS_MIN_OS)     <- colorwake needs 18.0
#       (Anvil floats with IPHONEOS_DEPLOYMENT_TARGET, default 13.0.)
#   * device-vs-simulator signing branch                <- colorwake ios script
#       (real identity -> sign; else simulator -> ad-hoc sign; else skip.)
#
# ── Caller-supplied interface (the embed contract) ──────────────────────────
#   CEPHEUS_CRATE                cargo package to build (e.g. pd-ffi)            [required]
#   CEPHEUS_LIB_NAME             dylib base name without lib/.dylib             [required]
#   CEPHEUS_FRAMEWORK_NAME       .framework + binary + dSYM base name           [required]
#   CEPHEUS_FRAMEWORK_BUNDLE_ID  the framework's CFBundleIdentifier (distinct   [required]
#                                  from the app id)
#   CEPHEUS_RUST_ROOT            abs path to the cargo workspace root           [required]
#   CEPHEUS_IOS_MIN_OS           MinimumOSVersion floor          [optional, default
#                                  ${IPHONEOS_DEPLOYMENT_TARGET:-13.0}; Colorwake=18.0]
#
# CEPHEUS_BUNDLE_ID (the app id) is part of the 6-var shim block but is not
# consumed here (the framework carries its own id); accepted/ignored.
#
# ── Xcode-provided environment (the caller never sets these) ────────────────
#   CONFIGURATION ARCHS PLATFORM_NAME BUILT_PRODUCTS_DIR FRAMEWORKS_FOLDER_PATH
#   IPHONEOS_DEPLOYMENT_TARGET DWARF_DSYM_FOLDER_PATH
#   EXPANDED_CODE_SIGN_IDENTITY CODE_SIGNING_ALLOWED
set -eu

: "${CEPHEUS_CRATE:?set CEPHEUS_CRATE to the cargo package to build}"
: "${CEPHEUS_LIB_NAME:?set CEPHEUS_LIB_NAME to the dylib base name (no lib/.dylib)}"
: "${CEPHEUS_FRAMEWORK_NAME:?set CEPHEUS_FRAMEWORK_NAME to the .framework base name}"
: "${CEPHEUS_FRAMEWORK_BUNDLE_ID:?set CEPHEUS_FRAMEWORK_BUNDLE_ID to the framework CFBundleIdentifier}"
: "${CEPHEUS_RUST_ROOT:?set CEPHEUS_RUST_ROOT to the cargo workspace root}"

RUST_ROOT="${CEPHEUS_RUST_ROOT}"

# MinimumOSVersion floor. Colorwake pins 18.0; everyone else floats with the
# Xcode deployment target (Anvil's original behavior).
IOS_MIN_OS="${CEPHEUS_IOS_MIN_OS:-${IPHONEOS_DEPLOYMENT_TARGET:-13.0}}"

case "${CONFIGURATION}" in
  Debug)
    CARGO_PROFILE="dev"
    TARGET_SUBDIR="debug"
    ;;
  *)
    CARGO_PROFILE="release"
    TARGET_SUBDIR="release"
    ;;
esac

# Resolve cargo/rustc via rustup and export RUSTC (sets RUSTUP, CARGO; exits on
# failure). See lib/rustup-resolve.sh — load-bearing, do not inline a bare
# `cargo` or `rustup run stable` here.
SCRIPT_DIR="$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)"
# SC1091: the fragment is resolved at runtime via $SCRIPT_DIR; it cannot be
# statically followed from an arbitrary CWD (e.g. an Xcode build dir).
# shellcheck source=../lib/rustup-resolve.sh disable=SC1091
. "${SCRIPT_DIR}/../lib/rustup-resolve.sh"

# Keep Rust line tables in optimized builds so the dSYM below can symbolicate
# release crashes (mirrors Colorwake's CARGO_PROFILE_RELEASE_DEBUG=line-tables-only).
# Harmless when CEPHEUS_FRAMEWORK has no dSYM consumer.
export CARGO_PROFILE_RELEASE_DEBUG="${CARGO_PROFILE_RELEASE_DEBUG:-line-tables-only}"

# Map (SDK, arch) -> Rust target triple. Device builds use the *-ios triple;
# simulator builds use the *-ios-sim (arm64) / x86_64-apple-ios (Intel) triples.
is_simulator=0
case "${PLATFORM_NAME:-iphoneos}" in
  *simulator*) is_simulator=1 ;;
esac

# SC2153: ARCHS is Xcode-provided environment (like CONFIGURATION), not a typo.
# shellcheck disable=SC2153
echo "==> Building ${CEPHEUS_CRATE} (${CARGO_PROFILE}) for ${PLATFORM_NAME:-iphoneos} arch(s): ${ARCHS}"
SLICES=""
for ARCH in ${ARCHS}; do
  case "${ARCH}" in
    arm64)
      if [ "${is_simulator}" -eq 1 ]; then
        RUST_TARGET="aarch64-apple-ios-sim"
      else
        RUST_TARGET="aarch64-apple-ios"
      fi
      ;;
    x86_64)
      RUST_TARGET="x86_64-apple-ios"
      ;;
    *) echo "error: unsupported arch '${ARCH}'" >&2; exit 1 ;;
  esac

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

# Stage the framework inside the built app's Frameworks folder. iOS uses shallow
# bundles, so this is a flat layout (binary + Info.plist at the top level), in
# contrast to the versioned macOS bundle in embed-rust-macos.sh.
FRAMEWORK_DIR="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}/${CEPHEUS_FRAMEWORK_NAME}.framework"
FRAMEWORK_BINARY="${FRAMEWORK_DIR}/${CEPHEUS_FRAMEWORK_NAME}"
rm -rf "${FRAMEWORK_DIR}"
mkdir -p "${FRAMEWORK_DIR}"

# shellcheck disable=SC2086
set -- ${SLICES}
if [ "$#" -gt 1 ]; then
  lipo -create "$@" -output "${FRAMEWORK_BINARY}"
else
  cp "$1" "${FRAMEWORK_BINARY}"
fi

install_name_tool -id "@rpath/${CEPHEUS_FRAMEWORK_NAME}.framework/${CEPHEUS_FRAMEWORK_NAME}" \
  "${FRAMEWORK_BINARY}"

# iOS embedded frameworks must carry an Info.plist to pass App Store validation
# (unlike the macOS local build, which tolerates a bare binary). Emit a minimal
# flat-bundle Info.plist with the MinimumOSVersion floor.
cat > "${FRAMEWORK_DIR}/Info.plist" <<PLIST
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
	<key>MinimumOSVersion</key>
	<string>${IOS_MIN_OS}</string>
</dict>
</plist>
PLIST

# Generate a dSYM for crash symbolication (Colorwake ships symbolicated
# TestFlight crashes; Anvil had no equivalent). Gated on Xcode providing a dSYM
# folder, with the dSYM basename = the framework name.
if command -v dsymutil >/dev/null 2>&1 && [ -n "${DWARF_DSYM_FOLDER_PATH:-}" ]; then
  mkdir -p "${DWARF_DSYM_FOLDER_PATH}"
  dsymutil "${FRAMEWORK_BINARY}" \
    -o "${DWARF_DSYM_FOLDER_PATH}/${CEPHEUS_FRAMEWORK_NAME}.framework.dSYM"
fi

# Sign the framework *bundle*. Device builds sign with the resolved identity;
# simulator builds (which have no real identity) fall back to an ad-hoc
# signature; otherwise signing is skipped (Colorwake's device-vs-sim branch).
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
  if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY:-}" != "-" ]; then
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none "${FRAMEWORK_DIR}"
  elif [ "${PLATFORM_NAME:-iphoneos}" = "iphonesimulator" ]; then
    /usr/bin/codesign --force --sign - --timestamp=none "${FRAMEWORK_DIR}"
  fi
fi

echo "==> Embedded ${CEPHEUS_FRAMEWORK_NAME}.framework into ${FRAMEWORKS_FOLDER_PATH}"
