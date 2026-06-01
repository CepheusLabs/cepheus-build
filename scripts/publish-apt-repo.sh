#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Publish .deb packages into a self-hosted, GPG-signed apt repository.
#
# Two gates, both fail-soft so this never breaks a build:
#   • GPG (GPG_SIGNING_KEY)  — signs the apt Release file. Unset → unsigned repo
#     metadata + warning (sourced from sign-linux-gpg.sh's ensure_gpg_key()).
#   • HOST (APT_REPO_TARGET) — rsync/scp/s3 destination to upload to. Unset →
#     build the repo tree locally under packaging/linux/dist/apt and stop, so
#     you can inspect it before a host is chosen (see INSTALLERS.md open items).
#
# Layout produced (flat repo, suite "stable", component "main"):
#   <repo>/pool/main/<pkg>.deb
#   <repo>/dists/stable/main/binary-amd64/Packages[.gz]
#   <repo>/dists/stable/Release[.gpg], InRelease
#
# Env:
#   APT_REPO_TARGET   upload destination, e.g. user@host:/srv/apt or s3://bucket/apt
#   APT_REPO_SUITE    suite name (default: stable)
#   APT_REPO_ARCH     dpkg arch (default: amd64)
#   GPG_SIGNING_KEY[_ID|_PASSPHRASE]  signing key material (see sign-linux-gpg.sh)
#   CBUILD_DRY_RUN=1  preview only
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# Reuse the GPG helper (ensure_gpg_key / is_dry_run) without running its main().
# shellcheck source=/dev/null
source "$TOOL_ROOT/scripts/sign-linux-gpg.sh"

SUITE="${APT_REPO_SUITE:-stable}"
ARCH="${APT_REPO_ARCH:-amd64}"
REPO_ROOT="${APT_REPO_LOCAL_DIR:-packaging/linux/dist/apt}"

debs=("$@")
if [ "${#debs[@]}" -eq 0 ]; then
  echo "usage: publish-apt-repo.sh <file.deb> [more.deb ...]" >&2
  exit 2
fi
for d in "${debs[@]}"; do
  [ -f "$d" ] || { echo "error: .deb not found: $d" >&2; exit 1; }
done

if is_dry_run; then
  echo "[dry-run] Would build apt repo ($SUITE/$ARCH) at $REPO_ROOT from:"
  for d in "${debs[@]}"; do echo "  $d"; done
  echo "[dry-run] Would sign Release with GPG and upload to ${APT_REPO_TARGET:-<unset>}"
  exit 0
fi

# Assemble the pool + dists tree.
pool="$REPO_ROOT/pool/main"
bindir="$REPO_ROOT/dists/$SUITE/main/binary-$ARCH"
mkdir -p "$pool" "$bindir"
for d in "${debs[@]}"; do cp -f "$d" "$pool/"; done

echo "==> Indexing packages"
if command -v dpkg-scanpackages >/dev/null 2>&1; then
  ( cd "$REPO_ROOT" && dpkg-scanpackages --arch "$ARCH" pool /dev/null > "dists/$SUITE/main/binary-$ARCH/Packages" )
else
  # Minimal fallback: dpkg-deb field extraction + size/hashes per package.
  : > "$bindir/Packages"
  for d in "$pool"/*.deb; do
    { dpkg-deb -f "$d"; printf 'Filename: pool/main/%s\n' "$(basename "$d")"; \
      printf 'Size: %s\n' "$(wc -c < "$d")"; \
      printf 'SHA256: %s\n\n' "$(sha256sum "$d" | cut -d' ' -f1)"; } >> "$bindir/Packages"
  done
fi
gzip -kf "$bindir/Packages"

echo "==> Writing Release"
release="$REPO_ROOT/dists/$SUITE/Release"
{
  echo "Suite: $SUITE"
  echo "Component: main"
  echo "Architectures: $ARCH"
  echo "Date: $(date -u '+%a, %d %b %Y %H:%M:%S UTC')"
} > "$release"

# GPG-sign the Release (detached Release.gpg + inline InRelease) if configured.
if key_id="$(ensure_gpg_key 2>/dev/null)"; then
  echo "==> Signing Release with $key_id"
  gpg --batch --yes --armor --detach-sign --local-user "$key_id" \
    ${GPG_SIGNING_KEY_PASSPHRASE:+--pinentry-mode loopback --passphrase "$GPG_SIGNING_KEY_PASSPHRASE"} \
    --output "$release.gpg" "$release"
  gpg --batch --yes --clearsign --local-user "$key_id" \
    ${GPG_SIGNING_KEY_PASSPHRASE:+--pinentry-mode loopback --passphrase "$GPG_SIGNING_KEY_PASSPHRASE"} \
    --output "$REPO_ROOT/dists/$SUITE/InRelease" "$release"
else
  echo "warning: GPG_SIGNING_KEY unset — apt repo metadata is UNSIGNED." >&2
fi

if [ -z "${APT_REPO_TARGET:-}" ]; then
  echo "==> Built local apt repo at $REPO_ROOT"
  echo "==> APT_REPO_TARGET unset — not uploading. Configure it to publish."
  exit 0
fi

echo "==> Uploading repo to $APT_REPO_TARGET"
# No --delete: package repos accumulate versions, and a shared target may also
# host sibling products. Deleting remote files would break older installs and
# wipe other products' artifacts.
case "$APT_REPO_TARGET" in
  s3://*) aws s3 sync "$REPO_ROOT/" "$APT_REPO_TARGET/" ;;
  *)      rsync -az "$REPO_ROOT/" "$APT_REPO_TARGET/" ;;
esac
echo "==> Published apt repo."
