#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Detached Ed25519 (EdDSA) signing for desktop auto-update artifacts
# (.dmg / .exe / .AppImage / .apk / delta). Uses the canonical RFC 8032 scheme
# that Sparkle + WinSparkle verify; signatures are byte-identical to Sparkle's
# sign_update from the same 32-byte seed.
#
# Signing is ENV-GATED: when CL_UPDATE_ED25519_PRIVATE_KEY is not set, this
# script prints a warning and exits 0, leaving artifacts UNSIGNED. Unsigned
# dev/CI builds "just work"; provide the key later to turn signing on with no
# code change. (Same contract as sign-linux-gpg.sh / sign-windows.ps1.)
#
# Usage:
#   scripts/sign-update-eddsa.sh <file> [<file> ...]
#
# Each <file> gets a base64 detached signature alongside it:
#   Anvil-1.4.0.dmg  ->  Anvil-1.4.0.dmg.sig   (base64 of the raw 64-byte sig)
# The signature covers the RAW, COMPLETE file bytes (no pre-hash, no framing).
# Verify with:  scripts/verify-update-eddsa.sh <pubkey_b64_or_file> <file>
#
# Environment:
#   CL_UPDATE_ED25519_PRIVATE_KEY   base64 of the 32-byte Ed25519 SEED.
#                                   Lives ONLY in CI secrets; never on disk.
#                                   96-byte legacy keys are rejected (seed
#                                   unrecoverable).
#
# CBUILD_DRY_RUN=1 previews actions without reading the key or signing.
#
# Requires python3 with pynacl. The seed is passed to python via the environment
# (masked by CI) and never written to disk or echoed.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

is_dry_run() {
  case "${CBUILD_DRY_RUN:-0}" in
    "" | 0 | false | no) return 1 ;;
    *) return 0 ;;
  esac
}

main() {
  local files=()
  for arg in "$@"; do
    case "$arg" in
      *) files+=("$arg") ;;
    esac
  done

  if [ -z "${CL_UPDATE_ED25519_PRIVATE_KEY:-}" ]; then
    echo "warning: CL_UPDATE_ED25519_PRIVATE_KEY unset — leaving update artifact(s) UNSIGNED." >&2
    # ${arr[@]+...} guards an empty array under `set -u` on bash 3.2 (macOS).
    for f in ${files[@]+"${files[@]}"}; do echo "    $f" >&2; done
    echo "warning: set CL_UPDATE_ED25519_PRIVATE_KEY (base64 32-byte seed) to enable signing (no code change needed)." >&2
    exit 0
  fi

  if is_dry_run; then
    echo "[dry-run] Would EdDSA-sign (raw file bytes) with CL_UPDATE_ED25519_PRIVATE_KEY:"
    for f in ${files[@]+"${files[@]}"}; do echo "  $f -> ${f}.sig"; done
    echo "[dry-run] No signing performed."
    exit 0
  fi

  command -v python3 >/dev/null 2>&1 || {
    echo "error: python3 not on PATH; cannot EdDSA-sign." >&2
    exit 1
  }
  if ! python3 -c "import nacl" >/dev/null 2>&1; then
    echo "error: pynacl not importable. Install it: python3 -m pip install pynacl" >&2
    exit 1
  fi

  if [ "${#files[@]}" -eq 0 ]; then
    echo "error: no files to sign." >&2
    exit 1
  fi

  # Validate the seed length ONCE, up front, so a rejected (e.g. 96-byte legacy)
  # key never prints a misleading "==> EdDSA-signing ..." status line first.
  python3 - <<'PY'
import base64
import os
import sys

seed_b64 = os.environ["CL_UPDATE_ED25519_PRIVATE_KEY"]
try:
    seed = base64.standard_b64decode(seed_b64)
except Exception:
    print("error: CL_UPDATE_ED25519_PRIVATE_KEY is not valid base64.", file=sys.stderr)
    sys.exit(1)

if len(seed) == 96:
    print("error: 96-byte legacy key supplied; the seed is unrecoverable from it. "
          "Supply the base64 32-byte SEED instead.", file=sys.stderr)
    sys.exit(1)
if len(seed) != 32:
    print(f"error: CL_UPDATE_ED25519_PRIVATE_KEY must decode to 32 bytes, got {len(seed)}.",
          file=sys.stderr)
    sys.exit(1)
PY

  for f in ${files[@]+"${files[@]}"}; do
    [ -f "$f" ] || { echo "error: file to sign not found: $f" >&2; exit 1; }
    echo "==> EdDSA-signing $f -> ${f}.sig"
    # The seed is read from os.environ inside python — never an arg, never on
    # disk, never echoed. Output is the base64 detached signature written to
    # <file>.sig by python directly.
    CL_SIGN_FILE="$f" CL_SIGN_SIG_FILE="${f}.sig" python3 - <<'PY'
import base64
import os
import sys

from nacl.signing import SigningKey

seed_b64 = os.environ["CL_UPDATE_ED25519_PRIVATE_KEY"]
try:
    seed = base64.standard_b64decode(seed_b64)
except Exception:
    print("error: CL_UPDATE_ED25519_PRIVATE_KEY is not valid base64.", file=sys.stderr)
    sys.exit(1)

if len(seed) == 96:
    print("error: 96-byte legacy key supplied; the seed is unrecoverable from it. "
          "Supply the base64 32-byte SEED instead.", file=sys.stderr)
    sys.exit(1)
if len(seed) != 32:
    print(f"error: CL_UPDATE_ED25519_PRIVATE_KEY must decode to 32 bytes, got {len(seed)}.",
          file=sys.stderr)
    sys.exit(1)

signing_key = SigningKey(seed)

artifact = os.environ["CL_SIGN_FILE"]
sig_file = os.environ["CL_SIGN_SIG_FILE"]

with open(artifact, "rb") as fh:
    data = fh.read()                       # raw complete file bytes

sig = signing_key.sign(data).signature     # raw 64-byte detached signature
assert len(sig) == 64, "Ed25519 signature must be 64 bytes"

with open(sig_file, "w") as fh:
    fh.write(base64.standard_b64encode(sig).decode("ascii") + "\n")
PY
  done
  echo "==> Signed ${#files[@]} update artifact(s)."
}

# Only run main() when executed directly so the file can be sourced for reuse.
# The ":-" guards `set -u` when BASH_SOURCE is unset.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
  main "$@"
fi
