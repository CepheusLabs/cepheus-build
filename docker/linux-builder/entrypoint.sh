#!/usr/bin/env bash
# Linux builder entrypoint: seed ssh trust, fix cache ownership, run sshd.
#
# AUTHORIZED_KEYS_FILE (mounted, default /authorized_keys) holds the dispatch
# hosts' public keys — the same trust model as the dockur VMs. The toolkit is
# bind-mounted at /opt/cepheus-build from the host checkout (kept fresh by
# `git pull` on errai), so the endpoint's launcher needs no rsync'd copy.
set -euo pipefail
export PATH="/usr/sbin:/sbin:${PATH}"

keys="${AUTHORIZED_KEYS_FILE:-/authorized_keys}"
if [ -f "$keys" ]; then
  mkdir -p /home/builder/.ssh
  cp "$keys" /home/builder/.ssh/authorized_keys
  chown -R builder:builder /home/builder/.ssh
  chmod 700 /home/builder/.ssh
  chmod 600 /home/builder/.ssh/authorized_keys
else
  echo "builder-entrypoint: WARNING: no authorized_keys at $keys; ssh logins will fail." >&2
fi

# Toolchain homes were installed by root in the base image; the builder user
# needs the caches writable (named volumes mount fresh as root).
for dir in /home/builder/.pub-cache /home/builder/.cargo/registry /home/builder/go/pkg/mod; do
  mkdir -p "$dir"
  chown -R builder:builder "$(dirname "$dir")" 2>/dev/null || chown -R builder:builder "$dir"
done

# Flutter/dart need a writable SDK dir for the builder user only when the
# sdk cache updates; grant group write instead of duplicating the SDK.
chmod -R g+w /opt/flutter 2>/dev/null || true
chgrp -R builder /opt/flutter 2>/dev/null || true

# sshd scrubs the container ENV, so remote commands would lose the toolchain
# PATH. Bash sources ~/.bashrc for ssh-spawned non-interactive shells, which
# makes this the one reliable hook.
if ! grep -q "cepheus-toolchains" /home/builder/.bashrc 2>/dev/null; then
  echo 'export PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/usr/local/go/bin:/root/go/bin:/home/builder/.cargo/bin:/usr/local/bin:$PATH" # cepheus-toolchains' \
    >> /home/builder/.bashrc
  chown builder:builder /home/builder/.bashrc
fi

exec /usr/sbin/sshd -D -e
