#!/usr/bin/env bash
# Entrypoint for the Cepheus Build Linux image. The container backend passes the
# full `cepheus-build build ...` invocation as the command; this just makes the
# toolchains discoverable and trusts the bind-mounted (host-owned) git tree,
# then execs the command. With no command it drops into an interactive shell.
set -euo pipefail

export PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/usr/local/go/bin:/root/go/bin:/root/.cargo/bin:${ANDROID_SDK_ROOT:-/opt/android-sdk}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT:-/opt/android-sdk}/platform-tools:${PATH}"

# Container/VM builds resolve first-party deps from committed pins, never the
# local sibling overrides. GOWORK=off makes Go ignore any go.work that slipped
# into the bind mount (the backend also passes -e GOWORK=off).
export GOWORK="${GOWORK:-off}"

# The product repo is bind-mounted from the host and owned by the host user;
# tell git it is safe so version stamping (git rev-list) works.
git config --global --add safe.directory '*' 2>/dev/null || true

if [ "$#" -eq 0 ]; then
  exec bash
fi
exec "$@"
