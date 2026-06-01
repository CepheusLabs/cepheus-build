#!/usr/bin/env bash
# package-macos-developerid.sh — shared Developer ID (direct-download) packaging
# for macOS, parameterized by env.
#
# Re-signs the Flutter-built .app with the Developer ID Application cert +
# hardened runtime, wraps it in a DMG, notarizes it, and staples the ticket.
# The result is a Gatekeeper-approved DMG you can host for direct download.
#
# This is the de-duplicated form of the byte-identical-minus-env-prefix scripts:
#   anvil/scripts/package-macos-developerid.sh
#   colorwake-studio/scripts/package-macos-developerid.sh
# The org Developer ID cert identity literal is baked as the default (it is
# identical across apps), and every per-app value is an env knob.
#
# Run on a macOS host after a successful build. NOT testable end-to-end without
# notarization credentials (see prereqs) — use <PREFIX>_SKIP_NOTARIZE=1 (or
# CEPHEUS_SKIP_NOTARIZE=1) to validate the sign + DMG steps without them.
#
# ── One-time prerequisites ──────────────────────────────────────────────
#   • Developer ID Application cert in the login keychain:
#       "Developer ID Application: Cepheus Labs, LLC (J2W5M4CY69)"
#   • A notarytool credential profile stored once:
#       xcrun notarytool store-credentials AC_NOTARY \
#         --apple-id you@cepheuslabs.com --team-id J2W5M4CY69 \
#         --password <app-specific-password>
#     (or --key/--key-id/--issuer for an App Store Connect API key)
#
# ── Required env (per-app; the product TOML / app wrapper sets these) ────────
#   CEPHEUS_APP_PATH       abs path to the built .app
#   CEPHEUS_APP_DIR        dir to run `flutter build macos` in
#   CEPHEUS_VOLNAME        DMG volume name (e.g. "Anvil")
#   CEPHEUS_DMG_NAME       output DMG filename (e.g. "Anvil-0.1.0.dmg")
#   CEPHEUS_ENTITLEMENTS   abs path to the app's DeveloperID.entitlements
#                          (STAYS per-app: Anvil needs disable-library-validation,
#                           Colorwake omits it — never baked in here)
#
# ── Optional env ────────────────────────────────────────────────────────────
#   CEPHEUS_ENV_PREFIX     legacy knob namespace (e.g. ANVIL / COLORWAKE). When
#                          set, the version/notary/skip/identity knobs below also
#                          read <PREFIX>_* so the existing product-TOML invocation
#                          (ANVIL_VERSION=... bash …) keeps working unchanged.
#   CEPHEUS_DEVID_IDENTITY (or <PREFIX>_DEVID_IDENTITY) signing identity
#                          [default: Developer ID Application: Cepheus Labs, LLC (J2W5M4CY69)]
#   CEPHEUS_NOTARY_PROFILE (or <PREFIX>_NOTARY_PROFILE) notarytool profile [default: AC_NOTARY]
#   CEPHEUS_VERSION        (or <PREFIX>_VERSION)      flutter --build-name [default: 0.0.0]
#   CEPHEUS_BUILD_NUMBER   (or <PREFIX>_BUILD_NUMBER) flutter --build-number [default: 1]
#   CEPHEUS_DIST_DIR       output dir [default: dist/macos under the repo root guess]
#   CEPHEUS_SKIP_NOTARIZE  (or <PREFIX>_SKIP_NOTARIZE) =1 -> sign + DMG only
set -euo pipefail

# resolve <name>: echo the first set of CEPHEUS_<name> / <PREFIX>_<name> / default
_prefix="${CEPHEUS_ENV_PREFIX:-}"
resolve() {
  # $1 = bare knob name (e.g. VERSION); $2 = default
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
VOLNAME="${CEPHEUS_VOLNAME:?set CEPHEUS_VOLNAME to the DMG volume name}"
DMG_NAME="${CEPHEUS_DMG_NAME:?set CEPHEUS_DMG_NAME to the output DMG filename}"
ENTITLEMENTS="${CEPHEUS_ENTITLEMENTS:?set CEPHEUS_ENTITLEMENTS to the app DeveloperID.entitlements}"

SIGN_ID="$(resolve DEVID_IDENTITY 'Developer ID Application: Cepheus Labs, LLC (J2W5M4CY69)')"
NOTARY_PROFILE="$(resolve NOTARY_PROFILE 'AC_NOTARY')"
VERSION="$(resolve VERSION '0.0.0')"
BUILD_NUMBER="$(resolve BUILD_NUMBER '1')"
SKIP_NOTARIZE="$(resolve SKIP_NOTARIZE '0')"
DIST_DIR="${CEPHEUS_DIST_DIR:-$(cd "$APP_DIR/../.." 2>/dev/null && pwd || echo "$PWD")/dist/macos}"
DMG="$DIST_DIR/$DMG_NAME"

echo "==> Building release .app (v$VERSION+$BUILD_NUMBER)"
( cd "$APP_DIR" && flutter build macos --release \
    --build-name="$VERSION" --build-number="$BUILD_NUMBER" )

echo "==> Re-signing nested frameworks + app (Developer ID, hardened runtime)"
# Sign inside-out: each nested framework bundle first (so its seal is already
# valid when the outer app is sealed), then the app itself with the distribution
# entitlements. `codesign --deep` is intentionally NOT used — Apple discourages
# it for distribution. This loop catches the embedded Rust core framework
# alongside the Flutter/plugin frameworks.
for fw in "$APP"/Contents/Frameworks/*.framework; do
  [ -e "$fw" ] || continue
  codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$fw"
done
codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# Gatekeeper assessment (will say "rejected" until the app is notarized; that's
# expected on a freshly-signed, not-yet-notarized bundle).
spctl --assess --type execute --verbose=2 "$APP" || true

echo "==> Building DMG"
mkdir -p "$DIST_DIR"
rm -f "$DMG"
# hdiutil keeps this dependency-free; swap in `create-dmg` for a styled volume
# (background, Applications symlink) if you want a prettier window.
hdiutil create -volname "$VOLNAME" -srcfolder "$APP" -ov -format UDZO "$DMG"

if [ "$SKIP_NOTARIZE" = "1" ]; then
  echo "==> SKIP_NOTARIZE=1 — skipping notarization."
  echo "==> Signed (not notarized): $DMG"
  exit 0
fi

echo "==> Notarizing (notarytool profile: $NOTARY_PROFILE) — this can take minutes"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Done: $DMG"
