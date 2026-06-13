# Persistent ssh-able Linux builder for the container backend's ssh transport.
# Lets a dispatch host run the LINUX leg on the errai pool exactly like the
# Windows/macOS VMs (rsync push -> ssh build -> rsync artifact pull) instead
# of needing a local docker engine. Toolchains come from the build image;
# caches persist in the compose named volumes.
FROM ghcr.io/cepheuslabs/cepheus-build-linux:latest

# The base image installs Rust under /root (700, unreadable by `builder`).
# Relocate the toolchain to a world-readable shared path so the builder user
# can run cargo/rustc; RUSTUP_HOME points the rustup proxies at it (set in the
# entrypoint's /etc/environment, since sshd scrubs the container ENV). The
# per-user CARGO_HOME stays writable (its registry is a cache volume).
ENV RUSTUP_HOME=/opt/rust/rustup
RUN set -eux; \
    export PATH="/usr/sbin:/sbin:${PATH}"; \
    apt-get update; \
    apt-get install -y --no-install-recommends openssh-server; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /run/sshd /opt/rust; \
    useradd -m -d /home/builder -s /bin/bash builder; \
    # Flutter SDK group-writability happens HERE, once: in the entrypoint it
    # forced an overlayfs copy-up of the whole ~3GB SDK on every container
    # recreate (minutes of silent boot delay).
    chgrp -R builder /opt/flutter; \
    chmod -R g+w /opt/flutter; \
    # Rust: move root's install to /opt/rust and make it readable by all users.
    mv /root/.rustup /opt/rust/rustup; \
    mv /root/.cargo /opt/rust/cargo; \
    chmod -R a+rX /opt/rust

COPY entrypoint.sh /usr/local/bin/builder-entrypoint.sh
RUN chmod +x /usr/local/bin/builder-entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/builder-entrypoint.sh"]
