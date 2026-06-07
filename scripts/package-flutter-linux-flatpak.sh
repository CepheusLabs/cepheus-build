#!/usr/bin/env bash
# Shared Flatpak single-file bundle builder for Flutter Linux bundles.
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
: "${CBUILD_MANIFEST:?Set CBUILD_MANIFEST}"

OUT_DIR="${CBUILD_OUT_DIR:-$CBUILD_REPO_ROOT/packaging/linux/dist}"
ICON_SRC="${CBUILD_ICON_SRC:-}"

[[ -d "$CBUILD_BUNDLE" ]] || { echo "Missing $CBUILD_BUNDLE; run the Linux build first"; exit 1; }
command -v flatpak-builder >/dev/null 2>&1 || { echo "flatpak-builder not found"; exit 1; }

STAGE="$OUT_DIR/flatpak-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/bundle"
cp -r "$CBUILD_BUNDLE/"* "$STAGE/bundle/"

cat > "$STAGE/$CBUILD_APP_ID.desktop" <<EOF
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
  cp "$ICON_SRC" "$STAGE/icon.png"
else
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xfc\xff\xff?\x03\x00\x05\xfe\x02\xfe\xa1V\xa3\x80\x00\x00\x00\x00IEND\xaeB`\x82' > "$STAGE/icon.png"
fi

BUILD_DIR="$OUT_DIR/flatpak-build"
REPO="$OUT_DIR/flatpak-repo"
rm -rf "$BUILD_DIR"
mkdir -p "$OUT_DIR"

GPG_ARGS=()
TOOL_OVERRIDE_ROOT="${CBUILD_TOOL_ROOT:-$TOOL_ROOT}"
SIGNER="${CBUILD_SIGNER:-$TOOL_OVERRIDE_ROOT/scripts/sign-linux-gpg.sh}"
if [[ -f "$SIGNER" && -n "${GPG_SIGNING_KEY:-}" ]]; then
  # shellcheck source=/dev/null
  source "$SIGNER"
  if key_id="$(ensure_gpg_key 2>/dev/null)"; then
    GPG_ARGS=(--gpg-sign="$key_id")
  fi
fi

echo "==> flatpak-builder (v$VERSION)"
cp "$CBUILD_MANIFEST" "$OUT_DIR/$CBUILD_APP_ID.yml"
flatpak-builder --force-clean --repo="$REPO" "${GPG_ARGS[@]}" \
  "$BUILD_DIR" "$OUT_DIR/$CBUILD_APP_ID.yml"

BUNDLE_OUT="$OUT_DIR/${CBUILD_APP}-${VERSION}.flatpak"
flatpak build-bundle "${GPG_ARGS[@]}" "$REPO" "$BUNDLE_OUT" "$CBUILD_APP_ID"
echo "Wrote $BUNDLE_OUT"

[[ -f "$SIGNER" ]] && bash "$SIGNER" "$BUNDLE_OUT" || true
