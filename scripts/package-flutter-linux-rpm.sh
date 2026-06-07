#!/usr/bin/env bash
# Shared RPM package builder for Flutter Linux bundles.
set -euo pipefail

VERSION="${1:-0.0.0-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
: "${CBUILD_REPO_ROOT:?Set CBUILD_REPO_ROOT}"
: "${CBUILD_BUNDLE:?Set CBUILD_BUNDLE}"
: "${CBUILD_APP:?Set CBUILD_APP}"
: "${CBUILD_APP_ID:?Set CBUILD_APP_ID}"
: "${CBUILD_DISPLAY_NAME:?Set CBUILD_DISPLAY_NAME}"
: "${CBUILD_COMMENT:?Set CBUILD_COMMENT}"
: "${CBUILD_DESCRIPTION:?Set CBUILD_DESCRIPTION}"
: "${CBUILD_PROJECT_URL:?Set CBUILD_PROJECT_URL}"

OUT_DIR="${CBUILD_OUT_DIR:-$CBUILD_REPO_ROOT/packaging/linux/dist}"
ICON_SRC="${CBUILD_ICON_SRC:-}"
RPM_VERSION="${VERSION//-/_}"

[[ -d "$CBUILD_BUNDLE" ]] || { echo "Missing $CBUILD_BUNDLE; run the Linux build first"; exit 1; }
command -v rpmbuild >/dev/null 2>&1 || { echo "rpmbuild not found"; exit 1; }

BUILD="$OUT_DIR/rpm"
rm -rf "$BUILD"
mkdir -p "$BUILD"/{BUILD,RPMS,SOURCES,SPECS,BUILDROOT}

STAGE="$BUILD/stage"
mkdir -p "$STAGE/usr/lib/$CBUILD_APP" \
         "$STAGE/usr/bin" \
         "$STAGE/usr/share/applications" \
         "$STAGE/usr/share/icons/hicolor/256x256/apps"
cp -r "$CBUILD_BUNDLE/"* "$STAGE/usr/lib/$CBUILD_APP/"
ln -sf "/usr/lib/$CBUILD_APP/$CBUILD_APP" "$STAGE/usr/bin/$CBUILD_APP"

cat > "$STAGE/usr/share/applications/$CBUILD_APP_ID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$CBUILD_DISPLAY_NAME
Comment=$CBUILD_COMMENT
Exec=$CBUILD_APP
Icon=$CBUILD_APP_ID
Categories=Graphics;Engineering;
Terminal=false
EOF

ICON_DST="$STAGE/usr/share/icons/hicolor/256x256/apps/$CBUILD_APP_ID.png"
if [[ -n "$ICON_SRC" && -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$ICON_DST"
else
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xfc\xff\xff?\x03\x00\x05\xfe\x02\xfe\xa1V\xa3\x80\x00\x00\x00\x00IEND\xaeB`\x82' > "$ICON_DST"
fi

cat > "$BUILD/SPECS/$CBUILD_APP.spec" <<EOF
Name:           $CBUILD_APP
Version:        $RPM_VERSION
Release:        1
Summary:        $CBUILD_COMMENT
License:        Proprietary
URL:            $CBUILD_PROJECT_URL
BuildArch:      x86_64
Requires:       gtk3
%description
$CBUILD_DESCRIPTION
%install
cp -r $STAGE/* %{buildroot}/
%files
/usr/lib/$CBUILD_APP
/usr/bin/$CBUILD_APP
/usr/share/applications/$CBUILD_APP_ID.desktop
/usr/share/icons/hicolor/256x256/apps/$CBUILD_APP_ID.png
EOF

mkdir -p "$OUT_DIR"
rpmbuild --define "_topdir $BUILD" \
         --define "_rpmdir $BUILD/RPMS" \
         --buildroot "$BUILD/BUILDROOT/stage" \
         -bb "$BUILD/SPECS/$CBUILD_APP.spec"

RPM="$(find "$BUILD/RPMS" -name '*.rpm' | head -1)"
DEST="$OUT_DIR/${CBUILD_APP}-${RPM_VERSION}-1.x86_64.rpm"
cp "$RPM" "$DEST"
echo "Wrote $DEST"

TOOL_OVERRIDE_ROOT="${CBUILD_TOOL_ROOT:-$TOOL_ROOT}"
SIGNER="${CBUILD_SIGNER:-$TOOL_OVERRIDE_ROOT/scripts/sign-linux-gpg.sh}"
[[ -f "$SIGNER" ]] && bash "$SIGNER" "$DEST" || echo "note: cepheus-build GPG signer not found; skipping signature"
