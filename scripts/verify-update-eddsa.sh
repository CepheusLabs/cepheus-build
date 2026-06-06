#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Verify detached Ed25519 (EdDSA) signatures for desktop auto-update artifacts.
# This is the CI gate BEFORE publish: a build must not ship an artifact whose
# .sig does not verify against the canonical public key.
#
# Unlike the signer, this is NOT env-gated — verification is mandatory when run.
# The public key is PUBLIC (it is the value in the contracts registry's
# signing_keys), so nothing here is secret.
#
# Usage:
#   scripts/verify-update-eddsa.sh <pubkey_b64_or_file> <file> [<file> ...]
#
# <pubkey_b64_or_file> is either the base64 of the raw 32-byte public key, or a
# path to a file containing it (e.g. keys/<slug>_ed25519.pub). For each <file>,
# the sibling <file>.sig (base64 of the raw 64-byte detached signature) is
# verified against the RAW file bytes.
#
# Exit 0 iff every signature verifies; exit 1 on the first failure (so CI fails
# the publish). CBUILD_DRY_RUN=1 previews the plan without verifying.
#
# Requires python3 with pynacl.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

is_dry_run() {
  case "${CBUILD_DRY_RUN:-0}" in
    "" | 0 | false | no) return 1 ;;
    *) return 0 ;;
  esac
}

usage() {
  echo "usage: scripts/verify-update-eddsa.sh <pubkey_b64_or_file> <file> [<file> ...]" >&2
  exit 1
}

main() {
  [ "$#" -ge 2 ] || usage
  local pubkey_arg="$1"
  shift

  local files=()
  for arg in "$@"; do
    files+=("$arg")
  done

  if is_dry_run; then
    echo "[dry-run] Would EdDSA-verify these artifacts against the supplied public key:"
    for f in ${files[@]+"${files[@]}"}; do echo "  $f  (sig: ${f}.sig)"; done
    echo "[dry-run] No verification performed."
    exit 0
  fi

  command -v python3 >/dev/null 2>&1 || {
    echo "error: python3 not on PATH; cannot EdDSA-verify." >&2
    exit 1
  }
  if ! python3 -c "import nacl" >/dev/null 2>&1; then
    echo "error: pynacl not importable. Install it: python3 -m pip install pynacl" >&2
    exit 1
  fi

  # Resolve the public key: a file path takes precedence, else treat as base64.
  local pubkey_b64
  if [ -f "$pubkey_arg" ]; then
    pubkey_b64="$(tr -d '[:space:]' < "$pubkey_arg")"
  else
    pubkey_b64="$pubkey_arg"
  fi

  local rc=0
  for f in ${files[@]+"${files[@]}"}; do
    [ -f "$f" ] || { echo "error: file to verify not found: $f" >&2; exit 1; }
    [ -f "${f}.sig" ] || { echo "error: signature not found: ${f}.sig" >&2; exit 1; }
    if CL_VERIFY_PUBKEY="$pubkey_b64" CL_VERIFY_FILE="$f" CL_VERIFY_SIG_FILE="${f}.sig" \
        python3 - <<'PY'
import base64
import os
import sys

from nacl.exceptions import BadSignatureError
from nacl.signing import VerifyKey

pubkey_b64 = os.environ["CL_VERIFY_PUBKEY"]
try:
    pub = base64.standard_b64decode(pubkey_b64)
except Exception:
    print("error: public key is not valid base64.", file=sys.stderr)
    sys.exit(2)
if len(pub) != 32:
    print(f"error: public key must decode to 32 bytes, got {len(pub)}.", file=sys.stderr)
    sys.exit(2)

artifact = os.environ["CL_VERIFY_FILE"]
sig_file = os.environ["CL_VERIFY_SIG_FILE"]

with open(sig_file) as fh:
    sig_b64 = fh.read().strip()
try:
    sig = base64.standard_b64decode(sig_b64)
except Exception:
    print(f"error: signature in {sig_file} is not valid base64.", file=sys.stderr)
    sys.exit(2)
if len(sig) != 64:
    print(f"error: signature must decode to 64 bytes, got {len(sig)}.", file=sys.stderr)
    sys.exit(2)

with open(artifact, "rb") as fh:
    data = fh.read()                       # raw complete file bytes

try:
    VerifyKey(pub).verify(data, sig)
except BadSignatureError:
    sys.exit(1)
sys.exit(0)
PY
    then
      echo "==> OK  $f"
    else
      echo "==> FAIL  $f (signature did not verify)" >&2
      rc=1
    fi
  done

  if [ "$rc" -ne 0 ]; then
    echo "error: one or more update artifacts failed EdDSA verification." >&2
    exit 1
  fi
  echo "==> Verified ${#files[@]} update artifact(s)."
}

# Only run main() when executed directly so the file can be sourced for reuse.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
  main "$@"
fi
