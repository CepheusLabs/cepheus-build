#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Detached GPG signing for Linux release artifacts (.deb / .rpm / .AppImage /
# .flatpak and checksum files).
#
# Signing is ENV-GATED: when GPG_SIGNING_KEY is not set, this script prints a
# warning and exits 0, leaving artifacts UNSIGNED. Unsigned dev/CI builds "just
# work"; provide the key later to turn signing on with no code change. (Same
# pattern as the macOS DMG and Windows Trusted Signing helpers.)
#
# Usage:
#   scripts/sign-linux-gpg.sh <file> [<file> ...]
#   scripts/sign-linux-gpg.sh --import-only        # just import the key
#
# Each <file> gets a detached, ASCII-armored signature alongside it:
#   foo.deb  ->  foo.deb.asc
# Verify with:  gpg --verify foo.deb.asc foo.deb
#
# This signs loose download artifacts. Package-repository metadata signing
# (apt Release / rpm headers / flatpak OSTree) lives in the repo-publish lanes,
# which source the same imported key via ensure_gpg_key().
#
# Environment (set all to enable):
#   GPG_SIGNING_KEY             armored private key, OR base64 of one
#   GPG_SIGNING_KEY_ID          key id / fingerprint / uid to sign with
#   GPG_SIGNING_KEY_PASSPHRASE  passphrase (optional; for non-interactive use)
#
# CBUILD_DRY_RUN=1 previews actions without importing keys or signing.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

is_dry_run() {
  case "${CBUILD_DRY_RUN:-0}" in
    "" | 0 | false | no) return 1 ;;
    *) return 0 ;;
  esac
}

# Import GPG_SIGNING_KEY into a throwaway keyring scoped to this run. Echoes the
# resolved key id on stdout. Safe to call repeatedly. Sourced by repo lanes too.
ensure_gpg_key() {
  if [ -z "${GPG_SIGNING_KEY:-}" ]; then
    return 1
  fi
  command -v gpg >/dev/null 2>&1 || {
    echo "warning: gpg not on PATH; cannot sign" >&2
    return 1
  }

  # Accept either a raw armored key or base64-encoded armored key.
  local material="$GPG_SIGNING_KEY"
  if ! printf '%s' "$material" | grep -q "BEGIN PGP"; then
    material="$(printf '%s' "$material" | base64 --decode 2>/dev/null || true)"
  fi
  if ! printf '%s' "$material" | grep -q "BEGIN PGP"; then
    echo "warning: GPG_SIGNING_KEY is not an armored or base64 PGP key" >&2
    return 1
  fi

  printf '%s' "$material" | gpg --batch --import >/dev/null 2>&1 || true

  # Resolve the signing key id: explicit override, else the first secret key.
  local key_id="${GPG_SIGNING_KEY_ID:-}"
  if [ -z "$key_id" ]; then
    key_id="$(gpg --list-secret-keys --with-colons 2>/dev/null \
      | awk -F: '/^sec:/ {print $5; exit}')"
  fi
  if [ -z "$key_id" ]; then
    echo "warning: could not resolve a GPG signing key id" >&2
    return 1
  fi
  printf '%s' "$key_id"
}

# gpg invocation with optional non-interactive passphrase.
gpg_sign_detached() {
  local key_id="$1" file="$2"
  local args=(--batch --yes --armor --detach-sign --local-user "$key_id")
  if [ -n "${GPG_SIGNING_KEY_PASSPHRASE:-}" ]; then
    args+=(--pinentry-mode loopback --passphrase "$GPG_SIGNING_KEY_PASSPHRASE")
  fi
  gpg "${args[@]}" --output "${file}.asc" "$file"
}

main() {
  local import_only=0
  local files=()
  for arg in "$@"; do
    case "$arg" in
      --import-only) import_only=1 ;;
      *) files+=("$arg") ;;
    esac
  done

  if [ -z "${GPG_SIGNING_KEY:-}" ]; then
    echo "warning: GPG_SIGNING_KEY unset — leaving Linux artifact(s) UNSIGNED." >&2
    if [ "$import_only" -eq 0 ]; then
      for f in "${files[@]}"; do echo "    $f" >&2; done
    fi
    echo "warning: set GPG_SIGNING_KEY to enable signing (no code change needed)." >&2
    exit 0
  fi

  if is_dry_run; then
    echo "[dry-run] Would import GPG_SIGNING_KEY and detached-sign:"
    for f in "${files[@]}"; do echo "  $f -> ${f}.asc"; done
    echo "[dry-run] No signing performed."
    exit 0
  fi

  local key_id
  key_id="$(ensure_gpg_key)" || {
    echo "error: GPG signing requested but key import failed." >&2
    exit 1
  }
  echo "==> GPG signing with key: $key_id"

  if [ "$import_only" -eq 1 ]; then
    echo "==> Key imported; --import-only requested, nothing to sign."
    exit 0
  fi

  for f in "${files[@]}"; do
    [ -f "$f" ] || { echo "error: file to sign not found: $f" >&2; exit 1; }
    echo "==> Signing $f -> ${f}.asc"
    gpg_sign_detached "$key_id" "$f"
  done
  echo "==> Signed ${#files[@]} artifact(s)."
}

# Only run main() when executed directly, so repo lanes can `source` this file
# to reuse ensure_gpg_key() without triggering a sign pass. The ":-" guards
# against `set -u` when sourced from a shell that doesn't set BASH_SOURCE.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
  main "$@"
fi
