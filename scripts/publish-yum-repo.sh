#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Publish .rpm packages into a self-hosted, GPG-signed yum/dnf repository.
#
# Two fail-soft gates (never break a build):
#   • GPG (GPG_SIGNING_KEY)  — signs each rpm + the repomd.xml. Unset → unsigned
#     + warning (ensure_gpg_key() from sign-linux-gpg.sh).
#   • HOST (YUM_REPO_TARGET) — upload destination. Unset → build the repo tree
#     locally under packaging/linux/dist/yum and stop.
#
# Requires createrepo_c (or createrepo) to generate repodata. rpm --addsign
# signs packages when a key is configured.
#
# Env:
#   YUM_REPO_TARGET   upload destination (user@host:/srv/yum or s3://bucket/yum)
#   GPG_SIGNING_KEY[_ID|_PASSPHRASE]  signing key material
#   CBUILD_DRY_RUN=1  preview only
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=/dev/null
source "$TOOL_ROOT/scripts/sign-linux-gpg.sh"

REPO_ROOT="${YUM_REPO_LOCAL_DIR:-packaging/linux/dist/yum}"

rpms=("$@")
if [ "${#rpms[@]}" -eq 0 ]; then
  echo "usage: publish-yum-repo.sh <file.rpm> [more.rpm ...]" >&2
  exit 2
fi
for r in "${rpms[@]}"; do
  [ -f "$r" ] || { echo "error: .rpm not found: $r" >&2; exit 1; }
done

if is_dry_run; then
  echo "[dry-run] Would build yum repo at $REPO_ROOT from:"
  for r in "${rpms[@]}"; do echo "  $r"; done
  echo "[dry-run] Would GPG-sign rpms + repodata and upload to ${YUM_REPO_TARGET:-<unset>}"
  exit 0
fi

mkdir -p "$REPO_ROOT"
for r in "${rpms[@]}"; do cp -f "$r" "$REPO_ROOT/"; done

# Sign each rpm if a key is configured (requires a gpg-agent + %_gpg_name).
if key_id="$(ensure_gpg_key 2>/dev/null)"; then
  echo "==> Signing rpms with $key_id"
  if command -v rpm >/dev/null 2>&1 && command -v rpmsign >/dev/null 2>&1; then
    rpmsign --define "_gpg_name $key_id" --addsign "$REPO_ROOT"/*.rpm || \
      echo "warning: rpm --addsign failed (needs interactive gpg-agent?)" >&2
  else
    echo "warning: rpmsign not available — rpms left unsigned." >&2
  fi
else
  echo "warning: GPG_SIGNING_KEY unset — rpms + repodata UNSIGNED." >&2
fi

echo "==> Generating repodata"
if command -v createrepo_c >/dev/null 2>&1; then
  createrepo_c --update "$REPO_ROOT"
elif command -v createrepo >/dev/null 2>&1; then
  createrepo --update "$REPO_ROOT"
else
  echo "error: createrepo_c/createrepo not installed; cannot build yum repo." >&2
  exit 1
fi

# Sign repomd.xml so dnf can verify metadata (repo_gpgcheck=1).
if key_id="$(ensure_gpg_key 2>/dev/null)"; then
  # Array form: an unquoted ${VAR:+...} would word-split a passphrase with spaces.
  pass_args=()
  [ -n "${GPG_SIGNING_KEY_PASSPHRASE:-}" ] && \
    pass_args=(--pinentry-mode loopback --passphrase "$GPG_SIGNING_KEY_PASSPHRASE")
  gpg --batch --yes --armor --detach-sign --local-user "$key_id" \
    ${pass_args[@]+"${pass_args[@]}"} \
    --output "$REPO_ROOT/repodata/repomd.xml.asc" "$REPO_ROOT/repodata/repomd.xml"
fi

if [ -z "${YUM_REPO_TARGET:-}" ]; then
  echo "==> Built local yum repo at $REPO_ROOT"
  echo "==> YUM_REPO_TARGET unset — not uploading. Configure it to publish."
  exit 0
fi

echo "==> Uploading repo to $YUM_REPO_TARGET"
# No --delete: yum repos accumulate versions and a shared target may host
# sibling products; deleting remote files would break older installs.
case "$YUM_REPO_TARGET" in
  s3://*) aws s3 sync "$REPO_ROOT/" "$YUM_REPO_TARGET/" ;;
  *)      rsync -az "$REPO_ROOT/" "$YUM_REPO_TARGET/" ;;
esac
echo "==> Published yum repo."
