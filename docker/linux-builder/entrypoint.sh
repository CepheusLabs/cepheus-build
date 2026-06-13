#!/usr/bin/env bash
# Linux builder entrypoint: seed ssh trust, fix cache ownership, run sshd.
#
# AUTHORIZED_KEYS_FILE (mounted, default /authorized_keys) holds the dispatch
# hosts' public keys — the same trust model as the dockur VMs. The toolkit is
# bind-mounted at /opt/cepheus-build from the host checkout (kept fresh by
# `git pull` on errai), so the endpoint's launcher needs no rsync'd copy.
set -euo pipefail
export PATH="/usr/sbin:/sbin:${PATH}"

# Persist sshd host keys across container recreates: a fresh image layer
# regenerates them, which makes every dispatch host's known_hosts entry a
# CHANGED key (accept-new rightly refuses). Generated once into the mounted
# volume, then reused.
# ssh-keygen -A -f <prefix> writes under <prefix>/etc/ssh and does NOT create
# the directories itself.
mkdir -p /etc/ssh/persistent/etc/ssh
if ! ls /etc/ssh/persistent/ssh_host_*_key >/dev/null 2>&1; then
  ssh-keygen -A -f /etc/ssh/persistent >/dev/null
  mv /etc/ssh/persistent/etc/ssh/ssh_host_* /etc/ssh/persistent/
fi
rm -rf /etc/ssh/persistent/etc
shopt -s nullglob
keyfiles=(/etc/ssh/persistent/ssh_host_*_key)
shopt -u nullglob
if [ "${#keyfiles[@]}" -eq 0 ]; then
  echo "builder-entrypoint: FATAL: no persistent host keys materialized" >&2
  exit 1
fi
printf 'HostKey %s\n' "${keyfiles[@]}" > /etc/ssh/sshd_config.d/10-persistent-hostkeys.conf

# The root-owned /opt/flutter triggers git's dubious-ownership guard for the
# builder user (the base image whitelists it only for root).
printf '[safe]\n\tdirectory = *\n' > /home/builder/.gitconfig
chown builder:builder /home/builder/.gitconfig

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

# Cache volumes mount root-owned when fresh; hand them to builder ONCE.
# Never -R an already-builder-owned tree: a populated pub cache has tens of
# thousands of files and a recursive chown stalls boot for minutes.
for dir in /home/builder/.pub-cache /home/builder/.cargo/registry /home/builder/go/pkg/mod; do
  mkdir -p "$dir"
  if [ "$(stat -c %U "$dir")" != "builder" ]; then
    chown -R builder:builder "$dir"
  fi
done
chown builder:builder /home/builder /home/builder/.cargo /home/builder/go /home/builder/go/pkg 2>/dev/null || true

# Flutter/dart need a writable SDK dir for the builder user only when the
# sdk cache updates; grant group write instead of duplicating the SDK.
chmod -R g+w /opt/flutter 2>/dev/null || true
chgrp -R builder /opt/flutter 2>/dev/null || true

# sshd scrubs the container ENV and Ubuntu's stock ~/.bashrc returns early
# for non-interactive shells, so neither carries the toolchain PATH into
# remote commands. /etc/environment is read by PAM for EVERY ssh session,
# shell- and interactivity-independent. NOTE: it is not shell-parsed -- the
# full literal path list is required (no $PATH expansion).
cat > /etc/environment <<'ENV'
PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/usr/local/go/bin:/home/builder/go/bin:/opt/rust/cargo/bin:/home/builder/.cargo/bin:/home/builder/.pub-cache/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
GOWORK=off
RUSTUP_HOME=/opt/rust/rustup
CARGO_HOME=/home/builder/.cargo
ENV

exec /usr/sbin/sshd -D -e
