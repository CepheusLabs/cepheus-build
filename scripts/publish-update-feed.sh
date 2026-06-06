#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Release bridge for the desktop auto-updater: for each built artifact, compute
# sha256 + EdDSA-sign, upload the bytes (and the .sig) to the R2 CDN bucket, then
# register a release row with the control plane via POST /v1/admin/releases using
# a printdeck.release-record/1 body.
#
# Phase-1 SCOPE (what this body actually does today): mac/win full installers
# (.dmg / .exe). For each file it uploads exactly two objects — the artifact and
# its <file>.sig — and posts a release-record with signature_target=file_bytes.
#
# Phase-1 TODOs (NOT emitted yet — do not assume they are):
#   • Android: populate version_code + apk_signer_sha256 on the release-record.
#   • AppImage: upload the .zsync control file and populate zsync_url/appimage_url.
# Until then this script uploads NO .zsync and leaves those enrichment fields off.
#
# Contract source of truth: printdeck-ecosystem-contracts
#   schemas/printdeck.release-record.v1.json
#   registry/update-distribution.json
#
# Publishing is ENV-GATED: when the publish token / R2 credentials are not set,
# this script prints a warning and exits 0 (nothing uploaded/registered). This
# lets the update_publish lane stay wired (enabled=false today) without breaking
# builds before the backend + bucket exist. Same contract as the other lanes.
#
# Usage:
#   scripts/publish-update-feed.sh [--product <slug>] [--channel <c>] \
#       [--version <v>] [--build <n>] [--platform <p>] [--arch <a>] \
#       <file> [<file> ...]
#
# Defaults derived from the CBUILD_* environment (set by cepheus-build):
#   product  = --product or $CBUILD_PRODUCT
#   channel  = --channel or $CBUILD_CHANNEL (release tag→stable, beta→beta,
#              scheduled→nightly; defaults to "stable" if unset)
#   version  = --version or $CBUILD_VERSION
#   build    = --build   or $CBUILD_BUILD_NUMBER
# platform/arch are inferred per-file from the extension when not given.
#
# Environment (set all to enable; the publish gate requires every one of these):
#   CL_UPDATE_ED25519_PRIVATE_KEY   base64 32-byte seed (delegated to sign-update-eddsa.sh)
#   CL_UPDATE_PUBLISH_TOKEN         bearer token for POST /v1/admin/releases
#   CL_UPDATE_API_BASE              control-plane base URL (default https://printdeck.app)
#   R2_ACCOUNT_ID                   Cloudflare R2 account id (forms the upload endpoint; REQUIRED)
#   R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET   R2 credentials + bucket
#   CL_UPDATE_CDN_BASE              public CDN base for the `url` field
#                                   (default https://cdn.printdeck.app)
#
# CBUILD_DRY_RUN=1 previews the full plan (hash/sign/upload/register) without
# performing network calls.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

is_dry_run() {
  case "${CBUILD_DRY_RUN:-0}" in
    "" | 0 | false | no) return 1 ;;
    *) return 0 ;;
  esac
}

# Map a filename to the contract platform enum (macos|windows|linux-appimage|android).
platform_for() {
  case "$1" in
    *.dmg) echo "macos" ;;
    *.exe) echo "windows" ;;
    *.AppImage) echo "linux-appimage" ;;
    *.apk) echo "android" ;;
    *) echo "" ;;
  esac
}

main() {
  local product="${CBUILD_PRODUCT:-}"
  local channel="${CBUILD_CHANNEL:-stable}"
  local version="${CBUILD_VERSION:-}"
  local build="${CBUILD_BUILD_NUMBER:-}"
  local platform_override=""
  local arch_override=""
  local files=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --product) product="$2"; shift 2 ;;
      --channel) channel="$2"; shift 2 ;;
      --version) version="$2"; shift 2 ;;
      --build) build="$2"; shift 2 ;;
      --platform) platform_override="$2"; shift 2 ;;
      --arch) arch_override="$2"; shift 2 ;;
      -*) echo "error: unknown flag: $1" >&2; exit 1 ;;
      *) files+=("$1"); shift ;;
    esac
  done

  # ENV gate — same warn+exit-0 contract as the signing lanes. R2_ACCOUNT_ID is
  # part of the gate: an R2 endpoint cannot be formed without it, and falling
  # back to the default AWS S3 endpoint would silently upload to the wrong bucket
  # (see the uploader below, which fails loudly if it is somehow still empty).
  if [ -z "${CL_UPDATE_PUBLISH_TOKEN:-}" ] || [ -z "${R2_ACCOUNT_ID:-}" ] \
     || [ -z "${R2_ACCESS_KEY_ID:-}" ] || [ -z "${R2_SECRET_ACCESS_KEY:-}" ] \
     || [ -z "${R2_BUCKET:-}" ]; then
    echo "warning: update-feed publish creds unset — NOT uploading or registering any release." >&2
    echo "warning: needs CL_UPDATE_PUBLISH_TOKEN + R2_ACCOUNT_ID/R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY/R2_BUCKET." >&2
    for f in ${files[@]+"${files[@]}"}; do echo "    $f" >&2; done
    echo "warning: set them to enable publishing (no code change needed)." >&2
    exit 0
  fi

  [ -n "$product" ] || { echo "error: product unknown (pass --product or set CBUILD_PRODUCT)." >&2; exit 1; }
  [ -n "$version" ] || { echo "error: version unknown (pass --version or set CBUILD_VERSION)." >&2; exit 1; }
  [ -n "$build" ] || { echo "error: build unknown (pass --build or set CBUILD_BUILD_NUMBER)." >&2; exit 1; }

  local api_base="${CL_UPDATE_API_BASE:-https://printdeck.app}"
  local cdn_base="${CL_UPDATE_CDN_BASE:-https://cdn.printdeck.app}"

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

  if [ "${#files[@]}" -eq 0 ]; then
    echo "warning: no artifacts passed to publish; nothing to do." >&2
    exit 0
  fi

  if is_dry_run; then
    echo "[dry-run] Update-feed publish plan for $product $version+$build ($channel):"
    for f in ${files[@]+"${files[@]}"}; do
      local p; p="${platform_override:-$(platform_for "$f")}"
      echo "  $f  ->  sha256 + EdDSA-sign  ->  upload ${cdn_base}/${product}/${channel}/${version}/$(basename "$f")  ->  POST ${api_base}/v1/admin/releases (platform=${p:-?})"
    done
    echo "[dry-run] No network calls performed."
    exit 0
  fi

  command -v python3 >/dev/null 2>&1 || { echo "error: python3 not on PATH." >&2; exit 1; }
  command -v curl >/dev/null 2>&1 || { echo "error: curl not on PATH." >&2; exit 1; }

  # Keep the bearer token out of argv (visible via ps / /proc on shared hosts):
  # write it to a 0600 temp file that curl reads with -H @file, trap-cleaned.
  local auth_hdr_file
  auth_hdr_file="$(mktemp)"
  chmod 600 "$auth_hdr_file"
  trap 'rm -f "$auth_hdr_file"' EXIT
  printf 'Authorization: Bearer %s\n' "$CL_UPDATE_PUBLISH_TOKEN" > "$auth_hdr_file"

  for f in ${files[@]+"${files[@]}"}; do
    [ -f "$f" ] || { echo "error: artifact not found: $f" >&2; exit 1; }
    local base_name platform arch sha256 url sig_b64
    base_name="$(basename "$f")"
    platform="${platform_override:-$(platform_for "$f")}"
    [ -n "$platform" ] || { echo "error: cannot infer platform for $f; pass --platform." >&2; exit 1; }
    arch="${arch_override:-universal}"

    echo "==> [$base_name] sha256 + EdDSA-sign"
    sha256="$(python3 - "$f" <<'PY'
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as fh:
    for chunk in iter(lambda: fh.read(1 << 20), b""):
        h.update(chunk)
print(h.hexdigest())
PY
)"

    # Sign via the shared signer (env-gated; produces <file>.sig). If the key is
    # unset the signer warns + exits 0 and no .sig appears — that's a hard error
    # at publish time, since a release row needs ed_signature.
    bash "$script_dir/sign-update-eddsa.sh" "$f"
    [ -f "${f}.sig" ] || {
      echo "error: ${f}.sig missing — set CL_UPDATE_ED25519_PRIVATE_KEY; cannot register an unsigned release." >&2
      exit 1
    }
    sig_b64="$(tr -d '[:space:]' < "${f}.sig")"

    url="${cdn_base}/${product}/${channel}/${version}/${base_name}"

    echo "==> [$base_name] upload bytes (+ .sig) to R2 bucket: $R2_BUCKET"
    # Upload via aws/rclone if available; otherwise this is the documented hook
    # where the org's R2 uploader plugs in. Keep the secret out of argv.
    if command -v aws >/dev/null 2>&1; then
      # R2 requires an explicit account-scoped endpoint. NEVER fall back to the
      # default AWS S3 endpoint — that would silently upload to the wrong place.
      if [ -z "${R2_ACCOUNT_ID:-}" ]; then
        echo "error: R2_ACCOUNT_ID is empty; refusing to upload via awscli to the default AWS S3 endpoint." >&2
        echo "error: set R2_ACCOUNT_ID (the Cloudflare R2 account id) so the endpoint can be formed." >&2
        exit 1
      fi
      local endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
      AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
        aws s3 cp "$f" "s3://${R2_BUCKET}/${product}/${channel}/${version}/${base_name}" \
          --endpoint-url "$endpoint"
      AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
        aws s3 cp "${f}.sig" "s3://${R2_BUCKET}/${product}/${channel}/${version}/${base_name}.sig" \
          --endpoint-url "$endpoint"
    else
      echo "error: no R2 uploader found (install awscli, or wire your org uploader here)." >&2
      exit 1
    fi

    local size
    size="$(python3 -c 'import os,sys; print(os.path.getsize(sys.argv[1]))' "$f")"

    echo "==> [$base_name] POST $api_base/v1/admin/releases"
    # Build the release-record body in python (no secrets in argv), then POST it
    # with the bearer token read from the environment by curl.
    local body
    body="$(CL_RR_PRODUCT="$product" CL_RR_CHANNEL="$channel" CL_RR_PLATFORM="$platform" \
            CL_RR_ARCH="$arch" CL_RR_VERSION="$version" CL_RR_BUILD="$build" \
            CL_RR_URL="$url" CL_RR_SIZE="$size" CL_RR_SHA256="$sha256" CL_RR_SIG="$sig_b64" \
            python3 - <<'PY'
import json, os, uuid, datetime

platform = os.environ["CL_RR_PLATFORM"]
# signature_target is ALWAYS file_bytes: the signer signs the raw file bytes for
# every platform. AppImage clients reassemble via zsync and verify those same raw
# bytes — there is no pre-hash variant. (Update Contracts v1 §3.) The record must
# never claim a target the signer did not produce.
sig_target = "file_bytes"
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

record = {
    "schema": "printdeck.release-record/1",
    "contract_version": "1.0.0",
    "id": uuid.uuid4().hex,
    "product": os.environ["CL_RR_PRODUCT"],
    "channel": os.environ["CL_RR_CHANNEL"],
    "platform": platform,
    "arch": os.environ["CL_RR_ARCH"],
    "version": os.environ["CL_RR_VERSION"],
    "build": int(os.environ["CL_RR_BUILD"]),
    "url": os.environ["CL_RR_URL"],
    "size": int(os.environ["CL_RR_SIZE"]),
    "sha256": os.environ["CL_RR_SHA256"],
    "ed_signature": os.environ["CL_RR_SIG"],
    "signature_target": sig_target,
    "mandatory": False,
    "rollout_pct": 0,
    "paused": True,
    "published_at": now,
    "signing_key_id": os.environ.get("CL_UPDATE_SIGNING_KEY_ID", "cl-update-ed25519-2026-06"),
}
print(json.dumps(record))
PY
)"

    # --fail makes curl exit non-zero on an HTTP error; the bearer token is read
    # from a 0600 temp file via -H @file (never in argv). Body via stdin (@-).
    printf '%s' "$body" | curl --fail --silent --show-error \
      -X POST "$api_base/v1/admin/releases" \
      -H @"$auth_hdr_file" \
      -H "Content-Type: application/json" \
      --data-binary @- >/dev/null
    echo "==> [$base_name] registered."
  done

  echo "==> Published ${#files[@]} update artifact(s) for $product $version+$build ($channel)."
}

# Only run main() when executed directly so the file can be sourced for reuse.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
  main "$@"
fi
