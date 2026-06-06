#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Generate a Cepheus Labs auto-update Ed25519 keypair (RFC 8032 / orlp/ed25519,
# the scheme Sparkle + WinSparkle use). Output encodings are CANONICAL:
#   • private = base64 of the raw 32-byte SEED   (NOT openssl PEM/DER)
#   • public  = base64 of the raw 32-byte pubkey (NOT PEM/OID)
# These match the EdDSA contract in printdeck-ecosystem-contracts
# (registry/update-distribution.json → signing) and pynacl's SigningKey(seed).
#
# This is a HUMAN-RUN tool, not a build/CI lane: it is NOT wired into any
# product TOML and does not auto-run. Run it once per app slug, capture the
# printed seed into the CI secret CL_UPDATE_ED25519_PRIVATE_KEY, paste the
# printed public key into update-distribution.json `signing_keys`, then DELETE
# the local seed file.
#
# Usage:
#   scripts/cl-update-keygen.sh <app_slug>
#
# Writes (into the gitignored keys/ dir, beside this repo root):
#   keys/<slug>_ed25519.seed   chmod 600   base64 32-byte seed (PRIVATE — never commit)
#   keys/<slug>_ed25519.pub                base64 32-byte public key (safe to share)
# and prints the seed to stdout, clearly fenced, for CI-secret capture.
#
# CBUILD_DRY_RUN=1 previews the actions without invoking python or writing keys.
#
# Requires python3 with pynacl (`python3 -c "import nacl"`); hints to install if
# absent. Never echoes the seed except in the single, explicitly-labelled
# capture block at the end (this tool's whole purpose is to emit it once).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

is_dry_run() {
  case "${CBUILD_DRY_RUN:-0}" in
    "" | 0 | false | no) return 1 ;;
    *) return 0 ;;
  esac
}

usage() {
  echo "usage: scripts/cl-update-keygen.sh <app_slug>" >&2
  exit 1
}

main() {
  local slug=""
  for arg in "$@"; do
    case "$arg" in
      -h | --help) usage ;;
      -*) echo "error: unknown flag: $arg" >&2; usage ;;
      *)
        if [ -n "$slug" ]; then
          echo "error: only one app_slug may be given" >&2
          usage
        fi
        slug="$arg"
        ;;
    esac
  done
  [ -n "$slug" ] || usage

  command -v python3 >/dev/null 2>&1 || {
    echo "error: python3 not on PATH; install Python 3 (the keygen uses pynacl)." >&2
    exit 1
  }
  if ! python3 -c "import nacl" >/dev/null 2>&1; then
    echo "error: pynacl not importable. Install it, e.g.:" >&2
    echo "    python3 -m pip install pynacl" >&2
    exit 1
  fi

  # keys/ sits at this repo root (gitignored). Resolve it relative to the script.
  local script_dir repo_root keys_dir seed_file pub_file
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  repo_root="$(cd "$script_dir/.." && pwd)"
  keys_dir="$repo_root/keys"
  seed_file="$keys_dir/${slug}_ed25519.seed"
  pub_file="$keys_dir/${slug}_ed25519.pub"

  if is_dry_run; then
    echo "[dry-run] Would generate an Ed25519 keypair for slug: $slug"
    echo "[dry-run]   seed -> $seed_file (chmod 600, base64 32-byte seed)"
    echo "[dry-run]   pub  -> $pub_file  (base64 32-byte public key)"
    echo "[dry-run] No keys generated."
    exit 0
  fi

  if [ -e "$seed_file" ] || [ -e "$pub_file" ]; then
    echo "error: key files already exist for '$slug'; refusing to overwrite:" >&2
    [ -e "$seed_file" ] && echo "    $seed_file" >&2
    [ -e "$pub_file" ] && echo "    $pub_file" >&2
    echo "error: remove them first if you really mean to regenerate." >&2
    exit 1
  fi

  mkdir -p "$keys_dir"
  echo "==> Generating Ed25519 update keypair for: $slug"

  # The seed is written by python directly to a 600-mode file (never via the
  # shell, so it can't leak into process args or here-strings). Public key and
  # the one-time capture block are emitted on python's stdout.
  CL_KEYGEN_SLUG="$slug" CL_KEYGEN_SEED_FILE="$seed_file" CL_KEYGEN_PUB_FILE="$pub_file" \
    python3 - <<'PY'
import base64
import os
import stat

from nacl.signing import SigningKey

slug = os.environ["CL_KEYGEN_SLUG"]
seed_file = os.environ["CL_KEYGEN_SEED_FILE"]
pub_file = os.environ["CL_KEYGEN_PUB_FILE"]

# 32-byte seed; pynacl == orlp/RFC8032 == Sparkle/WinSparkle from the same seed.
signing_key = SigningKey.generate()
seed = bytes(signing_key)                 # raw 32-byte seed
assert len(seed) == 32, "seed must be 32 bytes"
pub = bytes(signing_key.verify_key)       # raw 32-byte public key
assert len(pub) == 32, "public key must be 32 bytes"

seed_b64 = base64.standard_b64encode(seed).decode("ascii")
pub_b64 = base64.standard_b64encode(pub).decode("ascii")

# Write the seed to a 0600 file, created exclusively (no clobber).
fd = os.open(seed_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, stat.S_IRUSR | stat.S_IWUSR)
with os.fdopen(fd, "w") as f:
    f.write(seed_b64 + "\n")

with open(pub_file, "w") as f:
    f.write(pub_b64 + "\n")

print(f"==> Public key (base64 32-byte, safe to share): {pub_b64}")
print("")
print("================= CI SECRET — CAPTURE NOW, THEN DELETE THE SEED FILE =================")
print(f"  Set the CI secret CL_UPDATE_ED25519_PRIVATE_KEY for '{slug}' to (base64 32-byte seed):")
print("")
print(f"  {seed_b64}")
print("")
print("  Then: paste the public key above into the contracts registry")
print("        (registry/update-distribution.json -> signing.signing_keys), and")
print(f"        `rm {seed_file}` — the seed must live ONLY in the CI secret.")
print("=====================================================================================")
PY

  chmod 600 "$seed_file" 2>/dev/null || true
  echo "==> Wrote $pub_file (public, shareable)."
  echo "==> Wrote $seed_file (PRIVATE seed, chmod 600, gitignored). Delete it after CI capture."
}

# Only run main() when executed directly, so the file can be sourced for tests
# without generating keys. The ":-" guards `set -u` when BASH_SOURCE is unset.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
  main "$@"
fi
