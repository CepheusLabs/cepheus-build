#!/usr/bin/env bash
# Upload release artifacts to a GitHub Release, robustly.
#
#   upload-release.sh <tag> <glob>...
#
# Each <glob> is passed QUOTED by the caller and expanded here with nullglob, so:
#   - a glob that matches nothing is silently skipped (a single-host release run
#     legitimately has no cross-host artifacts — e.g. no .dmg on a Linux run),
#   - directories are filtered out (gh release upload only takes files, and the
#     packaging steps leave staging subdirs under dist/),
#   - if nothing matches at all, we exit 0 rather than fail the deploy.
#
# Without this, `gh release upload <unmatched-glob>` receives the literal glob
# string as a filename and errors.
set -euo pipefail
shopt -s nullglob

TAG="${1:?usage: upload-release.sh <tag> <glob>...}"
shift

files=()
for pat in "$@"; do
  # $pat is intentionally unquoted so it glob-expands (nullglob → nothing if no
  # match). Keep only regular files.
  for f in $pat; do
    [ -f "$f" ] && files+=("$f")
  done
done

if [ "${#files[@]}" -eq 0 ]; then
  echo "upload-release: no artifacts matched for $TAG; nothing to upload."
  exit 0
fi

echo "upload-release: uploading ${#files[@]} artifact(s) to $TAG:"
printf '  %s\n' "${files[@]}"
gh release upload "$TAG" "${files[@]}" --clobber
