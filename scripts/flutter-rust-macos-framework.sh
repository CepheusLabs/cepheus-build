#!/bin/sh
# Build a Rust cdylib for macOS and embed it as a versioned .framework in a
# Flutter macOS app bundle. Intended to be called from an Xcode Run Script phase
# via a tiny app-owned wrapper that exports the CBUILD_* metadata below.
set -eu

: "${CBUILD_RUST_ROOT:?Set CBUILD_RUST_ROOT to the repository root containing Cargo.toml}"
: "${CBUILD_RUST_PACKAGE:?Set CBUILD_RUST_PACKAGE to the Cargo package name}"
: "${CBUILD_LIBRARY_NAME:?Set CBUILD_LIBRARY_NAME to the dylib/framework executable name}"
: "${CBUILD_FRAMEWORK_IDENTIFIER:?Set CBUILD_FRAMEWORK_IDENTIFIER to the bundle id}"

FRAMEWORK_NAME="${CBUILD_FRAMEWORK_NAME:-$CBUILD_LIBRARY_NAME}"

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

RUSTUP="$(command -v rustup 2>/dev/null || true)"
if [ -z "${RUSTUP}" ] && [ -x "${HOME}/.cargo/bin/rustup" ]; then
  RUSTUP="${HOME}/.cargo/bin/rustup"
fi

CARGO="${CARGO:-}"
if [ -n "${RUSTUP}" ]; then
  CARGO="$("${RUSTUP}" which cargo 2>/dev/null || true)"
  RUSTC="$("${RUSTUP}" which rustc 2>/dev/null || true)"
  if [ -n "${RUSTC}" ]; then
    export RUSTC
  fi
fi
if [ -z "${CARGO}" ]; then
  CARGO="$(command -v cargo 2>/dev/null || true)"
fi
if [ -z "${CARGO}" ] && [ -x "${HOME}/.cargo/bin/cargo" ]; then
  CARGO="${HOME}/.cargo/bin/cargo"
fi
if [ -z "${CARGO}" ]; then
  echo "error: cargo not found. Install Rust from https://rustup.rs/ and ensure cargo is on PATH or at ~/.cargo/bin/cargo." >&2
  exit 1
fi

echo "==> Building ${CBUILD_RUST_PACKAGE} (${CARGO_PROFILE}) for macOS arch(s): ${ARCHS}"
SLICES=""
for ARCH in ${ARCHS}; do
  case "${ARCH}" in
    arm64) RUST_TARGET="aarch64-apple-darwin" ;;
    x86_64) RUST_TARGET="x86_64-apple-darwin" ;;
    *) echo "error: unsupported arch '${ARCH}'" >&2; exit 1 ;;
  esac

  if [ -n "${RUSTUP}" ]; then
    "${RUSTUP}" target add "${RUST_TARGET}" >/dev/null 2>&1 || true
  fi

  "${CARGO}" build \
    --profile "${CARGO_PROFILE}" \
    --target "${RUST_TARGET}" \
    --manifest-path "${CBUILD_RUST_ROOT}/Cargo.toml" \
    -p "${CBUILD_RUST_PACKAGE}"

  SLICES="${SLICES} ${CBUILD_RUST_ROOT}/target/${RUST_TARGET}/${TARGET_SUBDIR}/lib${CBUILD_LIBRARY_NAME}.dylib"
done

FRAMEWORK_DIR="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}/${FRAMEWORK_NAME}.framework"
rm -rf "${FRAMEWORK_DIR}"
mkdir -p "${FRAMEWORK_DIR}/Versions/A/Resources"

# shellcheck disable=SC2086
set -- ${SLICES}
if [ "$#" -gt 1 ]; then
  lipo -create "$@" -output "${FRAMEWORK_DIR}/Versions/A/${CBUILD_LIBRARY_NAME}"
else
  cp "$1" "${FRAMEWORK_DIR}/Versions/A/${CBUILD_LIBRARY_NAME}"
fi

install_name_tool -id "@rpath/${FRAMEWORK_NAME}.framework/${CBUILD_LIBRARY_NAME}" \
  "${FRAMEWORK_DIR}/Versions/A/${CBUILD_LIBRARY_NAME}"

cat > "${FRAMEWORK_DIR}/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>${CBUILD_LIBRARY_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${CBUILD_FRAMEWORK_IDENTIFIER}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${FRAMEWORK_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>${CBUILD_FRAMEWORK_SHORT_VERSION:-1.0}</string>
	<key>CFBundleVersion</key>
	<string>${CBUILD_FRAMEWORK_VERSION:-1}</string>
</dict>
</plist>
PLIST

ln -sfh A "${FRAMEWORK_DIR}/Versions/Current"
ln -sfh "Versions/Current/${CBUILD_LIBRARY_NAME}" "${FRAMEWORK_DIR}/${CBUILD_LIBRARY_NAME}"
ln -sfh Versions/Current/Resources "${FRAMEWORK_DIR}/Resources"

if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
  IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  codesign --force --sign "${IDENTITY}" --timestamp=none "${FRAMEWORK_DIR}"
fi

echo "==> Embedded ${FRAMEWORK_NAME}.framework into ${FRAMEWORKS_FOLDER_PATH}"
