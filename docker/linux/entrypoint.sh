#!/usr/bin/env bash
# Entrypoint for the Cepheus Build Linux image. The container backend passes
# the full `cepheus-build build ...` invocation as the command; this makes the
# toolchains discoverable, isolates the build from the host checkout, and
# execs the command. With no command it drops into an interactive shell.
set -euo pipefail

export PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/usr/local/go/bin:/root/go/bin:/root/.cargo/bin:${ANDROID_SDK_ROOT:-/opt/android-sdk}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT:-/opt/android-sdk}/platform-tools:${PATH}"

# Container/VM builds resolve first-party deps from committed pins, never the
# local sibling overrides. GOWORK=off makes Go ignore any go.work that slipped
# into the tree (the backend also passes -e GOWORK=off).
export GOWORK="${GOWORK:-off}"

git config --global --add safe.directory '*' 2>/dev/null || true

if [ "$#" -eq 0 ]; then
  exec bash
fi

# Copy-isolated build (the backend sets these): the host repo is mounted at
# CBUILD_SYNC_SOURCE and copied into the container-local workdir, minus the
# host's caches/outputs (CBUILD_SYNC_EXCLUDES) -- a bind-mounted .dart_tool/
# package_config.json would point dart at HOST SDK paths, and a container-side
# pub get would poison the host's dev setup right back. After a successful
# build, only the declared artifact roots (CBUILD_PULL_ROOTS) are written back
# to the mount, mirroring the ssh transport's rsync pull.
if [ -n "${CBUILD_SYNC_SOURCE:-}" ]; then
  excludes=()
  for pattern in ${CBUILD_SYNC_EXCLUDES:-}; do
    excludes+=(--exclude "${pattern}")
  done
  rsync -a --delete "${excludes[@]}" "${CBUILD_SYNC_SOURCE}/" ./

  rc=0
  "$@" || rc=$?

  if [ "${rc}" -eq 0 ]; then
    for root in ${CBUILD_PULL_ROOTS:-}; do
      if [ -e "./${root}" ]; then
        rsync -a --relative "./${root}" "${CBUILD_SYNC_SOURCE}/"
      else
        echo "warning: artifact root '${root}' was not produced by the build."
      fi
    done
  fi
  exit "${rc}"
fi

exec "$@"
