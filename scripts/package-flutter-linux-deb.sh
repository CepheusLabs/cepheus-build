#!/usr/bin/env bash
# Shared Debian package builder for Flutter Linux bundles.
set -euo pipefail

VERSION="${1:-0.0.0-dev}"
: "${CBUILD_REPO_ROOT:?Set CBUILD_REPO_ROOT}"
: "${CBUILD_BUNDLE:?Set CBUILD_BUNDLE}"
: "${CBUILD_APP:?Set CBUILD_APP}"
: "${CBUILD_APP_ID:?Set CBUILD_APP_ID}"
: "${CBUILD_DISPLAY_NAME:?Set CBUILD_DISPLAY_NAME}"
: "${CBUILD_COMMENT:?Set CBUILD_COMMENT}"
: "${CBUILD_DESCRIPTION:?Set CBUILD_DESCRIPTION}"

OUT_DIR="${CBUILD_OUT_DIR:-$CBUILD_REPO_ROOT/packaging/linux/dist}"
ICON_SRC="${CBUILD_ICON_SRC:-}"

[[ -d "$CBUILD_BUNDLE" ]] || { echo "Missing $CBUILD_BUNDLE; run the Linux build first"; exit 1; }

DEB_ROOT="$OUT_DIR/deb/${CBUILD_APP}_${VERSION}_amd64"
rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN" \
         "$DEB_ROOT/usr/lib/$CBUILD_APP" \
         "$DEB_ROOT/usr/bin" \
         "$DEB_ROOT/usr/share/applications" \
         "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps"

cp -r "$CBUILD_BUNDLE/"* "$DEB_ROOT/usr/lib/$CBUILD_APP/"
ln -sf "/usr/lib/$CBUILD_APP/$CBUILD_APP" "$DEB_ROOT/usr/bin/$CBUILD_APP"

cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: $CBUILD_APP
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Depends: libgtk-3-0, libblkid1, liblzma5
Maintainer: Cepheus Labs, LLC <support@cepheuslabs.com>
Description: $CBUILD_COMMENT
 $CBUILD_DESCRIPTION
EOF

cat > "$DEB_ROOT/usr/share/applications/$CBUILD_APP_ID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$CBUILD_DISPLAY_NAME
Comment=$CBUILD_COMMENT
Exec=$CBUILD_APP
Icon=$CBUILD_APP_ID
Categories=Graphics;Engineering;
Terminal=false
EOF

if [[ -n "$ICON_SRC" && -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$DEB_ROOT/usr/share/icons/hicolor/256x256/apps/$CBUILD_APP_ID.png"
fi

mkdir -p "$OUT_DIR"
DEB="$OUT_DIR/${CBUILD_APP}-${VERSION}-linux-amd64.deb"
dpkg-deb --build --root-owner-group "$DEB_ROOT" "$DEB"
echo "Wrote $DEB"

SIGNER="${CBUILD_SIGNER:-${CBUILD_TOOL_ROOT:-$CBUILD_REPO_ROOT/shared/cepheus-build}/scripts/sign-linux-gpg.sh}"
[[ -f "$SIGNER" ]] && bash "$SIGNER" "$DEB" || echo "note: shared GPG signer not found; skipping signature"
