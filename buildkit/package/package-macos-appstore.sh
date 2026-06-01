#!/usr/bin/env bash
# package-macos-appstore.sh — shared Mac App Store packaging for macOS,
# parameterized by env.
#
# Re-signs the Flutter-built .app with the Apple Distribution cert + the Mac App
# Store provisioning profile, builds a signed installer .pkg, and (optionally)
# uploads it to App Store Connect.
#
# De-duplicated form of the byte-identical-minus-env-prefix scripts:
#   anvil/scripts/package-macos-appstore.sh
#   colorwake-studio/scripts/package-macos-appstore.sh
# The org Apple Distribution + 3rd Party Mac Developer Installer identity
# literals are baked as defaults (identical across apps); every per-app value is
# an env knob.
#
# Run on a macOS host after a successful build. NOT testable end-to-end here: it
# needs a Mac App Store provisioning profile and an App Store Connect app record,
# neither of which can be created from this script.
#
# NOTE on native plugins: the App Store sandbox forbids loading non-bundled
# executable code. An app's OWN core framework (signed with this team) loads
# fine; a third-party native-plugin system (e.g. Anvil's dlopen'd plugins) will
# NOT — ship those via the Developer ID build instead. (This is policy the app
# owns via its entitlements, not something this script changes.)
#
# ── One-time prerequisites ──────────────────────────────────────────────
#   • App ID registered on the developer portal (matching the bundle id).
#   • A "Mac App Store" distribution provisioning profile downloaded.
#   • An app record on App Store Connect.
#   • Upload credentials: an App Store Connect API key, or an app-specific
#     password (see the upload step).
#
# ── Required env (per-app) ──────────────────────────────────────────────────
#   CEPHEUS_APP_PATH       abs path to the built .app
#   CEPHEUS_APP_DIR        dir to run `flutter build macos` in
#   CEPHEUS_PKG_NAME       output .pkg filename (e.g. "Anvil-0.1.0-appstore.pkg")
#   CEPHEUS_ENTITLEMENTS   abs path to the app's AppStore.entitlements (per-app)
#   CEPHEUS_MAS_PROFILE    (or <PREFIX>_MAS_PROFILE) path to the .provisionprofile
#
# ── Optional env ────────────────────────────────────────────────────────────
#   CEPHEUS_ENV_PREFIX            legacy knob namespace; the knobs below also read
#                                 <PREFIX>_* when set (back-compat with the TOMLs).
#   CEPHEUS_MAS_APP_IDENTITY       [default: Apple Distribution: Cepheus Labs, LLC (J2W5M4CY69)]
#   CEPHEUS_MAS_INSTALLER_IDENTITY [default: 3rd Party Mac Developer Installer: Cepheus Labs, LLC (J2W5M4CY69)]
#   CEPHEUS_VERSION / CEPHEUS_BUILD_NUMBER   flutter build name/number [default 0.0.0 / 1]
#   CEPHEUS_DIST_DIR             output dir [default: dist/macos under the repo root guess]
#   CEPHEUS_MAS_UPLOAD           (or <PREFIX>_MAS_UPLOAD) =1 -> upload after building
#   CEPHEUS_ASC_APPLE_ID / CEPHEUS_ASC_PASSWORD  upload creds (app-specific password)
set -euo pipefail

_prefix="${CEPHEUS_ENV_PREFIX:-}"
resolve() {
  local cepheus_name="CEPHEUS_$1"
  if [ -n "${!cepheus_name:-}" ]; then
    printf '%s' "${!cepheus_name}"
    return
  fi
  if [ -n "${_prefix}" ]; then
    local pref_name="${_prefix}_$1"
    if [ -n "${!pref_name:-}" ]; then
      printf '%s' "${!pref_name}"
      return
    fi
  fi
  printf '%s' "$2"
}

APP="${CEPHEUS_APP_PATH:?set CEPHEUS_APP_PATH to the built .app}"
APP_DIR="${CEPHEUS_APP_DIR:?set CEPHEUS_APP_DIR to the flutter app dir}"
PKG_NAME="${CEPHEUS_PKG_NAME:?set CEPHEUS_PKG_NAME to the output .pkg filename}"
ENTITLEMENTS="${CEPHEUS_ENTITLEMENTS:?set CEPHEUS_ENTITLEMENTS to the app AppStore.entitlements}"

PROFILE="$(resolve MAS_PROFILE '')"
if [ -z "$PROFILE" ]; then
  echo "error: set CEPHEUS_MAS_PROFILE (or <PREFIX>_MAS_PROFILE) to your Mac App Store .provisionprofile" >&2
  exit 1
fi

APP_SIGN_ID="$(resolve MAS_APP_IDENTITY 'Apple Distribution: Cepheus Labs, LLC (J2W5M4CY69)')"
PKG_SIGN_ID="$(resolve MAS_INSTALLER_IDENTITY '3rd Party Mac Developer Installer: Cepheus Labs, LLC (J2W5M4CY69)')"
VERSION="$(resolve VERSION '0.0.0')"
BUILD_NUMBER="$(resolve BUILD_NUMBER '1')"
MAS_UPLOAD="$(resolve MAS_UPLOAD '0')"
DIST_DIR="${CEPHEUS_DIST_DIR:-$(cd "$APP_DIR/../.." 2>/dev/null && pwd || echo "$PWD")/dist/macos}"
PKG="$DIST_DIR/$PKG_NAME"

echo "==> Building release .app (v$VERSION+$BUILD_NUMBER)"
( cd "$APP_DIR" && flutter build macos --release \
    --build-name="$VERSION" --build-number="$BUILD_NUMBER" )

echo "==> Embedding provisioning profile"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

echo "==> Re-signing nested frameworks + app (Apple Distribution)"
# MAS builds are reviewed, not notarized, so no hardened-runtime option.
for fw in "$APP"/Contents/Frameworks/*.framework; do
  [ -e "$fw" ] || continue
  codesign --force --timestamp --sign "$APP_SIGN_ID" "$fw"
done
codesign --force --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$APP_SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Building signed installer .pkg"
mkdir -p "$DIST_DIR"
rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$PKG_SIGN_ID" "$PKG"

if [ "$MAS_UPLOAD" != "1" ]; then
  echo "==> Built (not uploaded): $PKG"
  echo "    Upload with Transporter.app, or set CEPHEUS_MAS_UPLOAD=1 (or"
  echo "    <PREFIX>_MAS_UPLOAD=1) and provide App Store Connect credentials."
  exit 0
fi

echo "==> Uploading to App Store Connect"
# App-specific-password path (altool); for an API key use --apiKey/--apiIssuer.
# notarytool is NOT used for App Store delivery.
xcrun altool --upload-app -f "$PKG" -t macos \
  --apple-id "${CEPHEUS_ASC_APPLE_ID:?Set CEPHEUS_ASC_APPLE_ID}" \
  --password "${CEPHEUS_ASC_PASSWORD:?Set CEPHEUS_ASC_PASSWORD (app-specific password)}"

echo "==> Done: $PKG"
