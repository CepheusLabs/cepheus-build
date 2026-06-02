#!/usr/bin/env bash
# Shared Developer ID packaging for Flutter macOS apps.
set -euo pipefail

env_or_default() {
  local name="$1"
  local fallback="$2"
  local value="${!name-}"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

: "${CBUILD_REPO_ROOT:?Set CBUILD_REPO_ROOT}"
: "${CBUILD_APP_DIR:?Set CBUILD_APP_DIR}"
: "${CBUILD_APP_BUNDLE_NAME:?Set CBUILD_APP_BUNDLE_NAME}"
: "${CBUILD_ARTIFACT_BASENAME:?Set CBUILD_ARTIFACT_BASENAME}"
: "${CBUILD_VOLUME_NAME:?Set CBUILD_VOLUME_NAME}"
: "${CBUILD_ENTITLEMENTS:?Set CBUILD_ENTITLEMENTS}"
: "${CBUILD_ENV_PREFIX:?Set CBUILD_ENV_PREFIX}"

SIGN_ID="$(env_or_default "${CBUILD_ENV_PREFIX}_DEVID_IDENTITY" "Developer ID Application: Cepheus Labs, LLC (J2W5M4CY69)")"
NOTARY_PROFILE="$(env_or_default "${CBUILD_ENV_PREFIX}_NOTARY_PROFILE" "AC_NOTARY")"
VERSION="$(env_or_default "${CBUILD_ENV_PREFIX}_VERSION" "${CBUILD_DEFAULT_VERSION:-0.0.0-dev}")"
BUILD_NUMBER="$(env_or_default "${CBUILD_ENV_PREFIX}_BUILD_NUMBER" "1")"
SKIP_NOTARIZE="$(env_or_default "${CBUILD_ENV_PREFIX}_SKIP_NOTARIZE" "0")"

APP="${CBUILD_APP_DIR}/build/macos/Build/Products/Release/${CBUILD_APP_BUNDLE_NAME}"
DIST_DIR="${CBUILD_DIST_DIR:-$CBUILD_REPO_ROOT/dist/macos}"
DMG="$DIST_DIR/${CBUILD_ARTIFACT_BASENAME}-${VERSION}.dmg"

echo "==> Building release .app (v${VERSION}+${BUILD_NUMBER})"
( cd "$CBUILD_APP_DIR" && flutter build macos --release \
    --build-name="$VERSION" --build-number="$BUILD_NUMBER" )

echo "==> Re-signing nested frameworks + app (Developer ID, hardened runtime)"
for fw in "$APP"/Contents/Frameworks/*.framework; do
  [[ -e "$fw" ]] || continue
  codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$fw"
done
codesign --force --timestamp --options runtime \
  --entitlements "$CBUILD_ENTITLEMENTS" --sign "$SIGN_ID" "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP" || true

echo "==> Building DMG"
mkdir -p "$DIST_DIR"
rm -f "$DMG"
hdiutil create -volname "$CBUILD_VOLUME_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"

if [[ "$SKIP_NOTARIZE" == "1" ]]; then
  echo "==> ${CBUILD_ENV_PREFIX}_SKIP_NOTARIZE=1; skipping notarization."
  echo "==> Signed (not notarized): $DMG"
  exit 0
fi

echo "==> Notarizing (notarytool profile: $NOTARY_PROFILE)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Done: $DMG"
