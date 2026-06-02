#!/usr/bin/env bash
# Shared Mac App Store packaging for Flutter macOS apps.
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

env_required() {
  local name="$1"
  local message="$2"
  local value="${!name-}"
  if [[ -z "$value" ]]; then
    echo "$message" >&2
    exit 1
  fi
  printf '%s' "$value"
}

: "${CBUILD_REPO_ROOT:?Set CBUILD_REPO_ROOT}"
: "${CBUILD_APP_DIR:?Set CBUILD_APP_DIR}"
: "${CBUILD_APP_BUNDLE_NAME:?Set CBUILD_APP_BUNDLE_NAME}"
: "${CBUILD_ARTIFACT_BASENAME:?Set CBUILD_ARTIFACT_BASENAME}"
: "${CBUILD_ENTITLEMENTS:?Set CBUILD_ENTITLEMENTS}"
: "${CBUILD_ENV_PREFIX:?Set CBUILD_ENV_PREFIX}"

APP_SIGN_ID="$(env_or_default "${CBUILD_ENV_PREFIX}_MAS_APP_IDENTITY" "Apple Distribution: Cepheus Labs, LLC (J2W5M4CY69)")"
PKG_SIGN_ID="$(env_or_default "${CBUILD_ENV_PREFIX}_MAS_INSTALLER_IDENTITY" "3rd Party Mac Developer Installer: Cepheus Labs, LLC (J2W5M4CY69)")"
PROFILE="$(env_required "${CBUILD_ENV_PREFIX}_MAS_PROFILE" "Set ${CBUILD_ENV_PREFIX}_MAS_PROFILE to your Mac App Store .provisionprofile")"
VERSION="$(env_or_default "${CBUILD_ENV_PREFIX}_VERSION" "${CBUILD_DEFAULT_VERSION:-0.0.0-dev}")"
BUILD_NUMBER="$(env_or_default "${CBUILD_ENV_PREFIX}_BUILD_NUMBER" "1")"
UPLOAD="$(env_or_default "${CBUILD_ENV_PREFIX}_MAS_UPLOAD" "0")"

APP="${CBUILD_APP_DIR}/build/macos/Build/Products/Release/${CBUILD_APP_BUNDLE_NAME}"
DIST_DIR="${CBUILD_DIST_DIR:-$CBUILD_REPO_ROOT/dist/macos}"
PKG="$DIST_DIR/${CBUILD_ARTIFACT_BASENAME}-${VERSION}-appstore.pkg"

echo "==> Building release .app (v${VERSION}+${BUILD_NUMBER})"
( cd "$CBUILD_APP_DIR" && flutter build macos --release \
    --build-name="$VERSION" --build-number="$BUILD_NUMBER" )

echo "==> Embedding provisioning profile"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

echo "==> Re-signing nested frameworks + app (Apple Distribution)"
for fw in "$APP"/Contents/Frameworks/*.framework; do
  [[ -e "$fw" ]] || continue
  codesign --force --timestamp --sign "$APP_SIGN_ID" "$fw"
done
codesign --force --timestamp \
  --entitlements "$CBUILD_ENTITLEMENTS" --sign "$APP_SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Building signed installer .pkg"
mkdir -p "$DIST_DIR"
rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$PKG_SIGN_ID" "$PKG"

if [[ "$UPLOAD" != "1" ]]; then
  echo "==> Built (not uploaded): $PKG"
  echo "    Upload with Transporter.app, or set ${CBUILD_ENV_PREFIX}_MAS_UPLOAD=1."
  exit 0
fi

echo "==> Uploading to App Store Connect"
ASC_APPLE_ID="$(env_required "${CBUILD_ENV_PREFIX}_ASC_APPLE_ID" "Set ${CBUILD_ENV_PREFIX}_ASC_APPLE_ID")"
ASC_PASSWORD="$(env_required "${CBUILD_ENV_PREFIX}_ASC_PASSWORD" "Set ${CBUILD_ENV_PREFIX}_ASC_PASSWORD")"
xcrun altool --upload-app -f "$PKG" -t macos \
  --apple-id "$ASC_APPLE_ID" \
  --password "$ASC_PASSWORD"

echo "==> Done: $PKG"
