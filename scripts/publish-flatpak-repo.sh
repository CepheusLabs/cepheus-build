#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Publish a single-file .flatpak bundle into a self-hosted, GPG-signed OSTree
# Flatpak repository (the kind users `flatpak remote-add` and get updates from).
#
# Two fail-soft gates (never break a build):
#   • GPG (GPG_SIGNING_KEY)     — signs the OSTree summary/commits. Unset →
#     unsigned repo + warning (ensure_gpg_key() from sign-linux-gpg.sh).
#   • HOST (FLATPAK_REPO_TARGET) — upload destination. Unset → build/update the
#     OSTree repo locally under packaging/linux/dist/flatpak-repo and stop.
#
# Consumes .flatpak single-file bundles (produced by `flatpak build-bundle`)
# and re-imports them into the repo via `flatpak build-import-bundle`.
#
# Env:
#   FLATPAK_REPO_TARGET   upload destination (user@host:/srv/flatpak or s3://...)
#   GPG_SIGNING_KEY[_ID|_PASSPHRASE]  signing key material
#   CBUILD_DRY_RUN=1      preview only
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=/dev/null
source "$TOOL_ROOT/scripts/sign-linux-gpg.sh"

REPO_ROOT="${FLATPAK_REPO_LOCAL_DIR:-packaging/linux/dist/flatpak-repo}"

bundles=("$@")
if [ "${#bundles[@]}" -eq 0 ]; then
  echo "usage: publish-flatpak-repo.sh <file.flatpak> [more.flatpak ...]" >&2
  exit 2
fi
for b in "${bundles[@]}"; do
  [ -f "$b" ] || { echo "error: .flatpak not found: $b" >&2; exit 1; }
done

if is_dry_run; then
  echo "[dry-run] Would import into OSTree flatpak repo at $REPO_ROOT:"
  for b in "${bundles[@]}"; do echo "  $b"; done
  echo "[dry-run] Would GPG-sign summary and upload to ${FLATPAK_REPO_TARGET:-<unset>}"
  exit 0
fi

command -v flatpak >/dev/null 2>&1 || {
  echo "error: flatpak not installed; cannot build flatpak repo." >&2
  exit 1
}

mkdir -p "$REPO_ROOT"

# Resolve optional GPG signing args once.
gpg_args=()
if key_id="$(ensure_gpg_key 2>/dev/null)"; then
  echo "==> Flatpak repo will be signed with $key_id"
  gpg_args=(--gpg-sign="$key_id")
  [ -n "${GNUPGHOME:-}" ] && gpg_args+=(--gpg-homedir="$GNUPGHOME")
else
  echo "warning: GPG_SIGNING_KEY unset — flatpak repo will be UNSIGNED." >&2
fi

for b in "${bundles[@]}"; do
  echo "==> Importing $b"
  flatpak build-import-bundle "${gpg_args[@]}" "$REPO_ROOT" "$b"
done

echo "==> Updating repo summary"
flatpak build-update-repo "${gpg_args[@]}" "$REPO_ROOT"

if [ -z "${FLATPAK_REPO_TARGET:-}" ]; then
  echo "==> Built local flatpak repo at $REPO_ROOT"
  echo "==> FLATPAK_REPO_TARGET unset — not uploading. Configure it to publish."
  exit 0
fi

echo "==> Uploading repo to $FLATPAK_REPO_TARGET"
case "$FLATPAK_REPO_TARGET" in
  s3://*) aws s3 sync "$REPO_ROOT/" "$FLATPAK_REPO_TARGET/" --delete ;;
  *)      rsync -az --delete "$REPO_ROOT/" "$FLATPAK_REPO_TARGET/" ;;
esac
echo "==> Published flatpak repo."
