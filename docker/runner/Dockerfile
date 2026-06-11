# Cepheus Build — first-party GitHub Actions runner image (Linux).
#
# Wraps the proven Linux build toolchain image with the GitHub Actions runner
# so jobs labelled [self-hosted, linux] execute with the exact same Flutter /
# Go / Rust / Android / packaging toolchains as `--execution-mode container`
# builds (release-pipeline plan Phase 1.1, locked decision L6). The entrypoint
# registers an EPHEMERAL org-scoped runner and re-registers in a loop after
# every job, so each job gets a pristine runner registration while the
# container (and its mounted tool caches) persists. See README.md.
FROM ghcr.io/cepheuslabs/cepheus-build-linux:latest

# Pin via build-arg when reproducibility matters; the default resolves the
# latest actions/runner release at image build time. Runner auto-update is ON
# (L6), so the baked version only matters for the first job after a rebuild.
ARG RUNNER_VERSION=""

# ── docker CLI + gh CLI ──────────────────────────────────────────────────────
# The base toolchain image carries neither. docker (CLI only — the daemon is
# the host's, via the mounted socket) backs docker-publish workflows; gh backs
# the entrypoint's registration-token fetch and the `gh release` store lanes.
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
        > /etc/apt/sources.list.d/docker.list; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        docker-ce-cli docker-buildx-plugin docker-compose-plugin \
        gh jq; \
    rm -rf /var/lib/apt/lists/*

# ── Dedicated non-root runner user ───────────────────────────────────────────
# config.sh refuses to run as root; jobs also expect a non-root user with
# passwordless sudo (app-build.yml installs apt packages with `sudo`). The
# docker group GID is aligned to the host's mounted socket at container start
# (entrypoint.sh root phase).
RUN set -eux; \
    useradd -m -d /home/runner -s /bin/bash runner; \
    echo "runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner; \
    chmod 0440 /etc/sudoers.d/runner; \
    groupadd -f docker; \
    usermod -aG docker runner

# ── actions/runner ───────────────────────────────────────────────────────────
RUN set -eux; \
    version="${RUNNER_VERSION}"; \
    if [ -z "$version" ]; then \
        version="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
            | jq -r '.tag_name | ltrimstr("v")')"; \
    fi; \
    mkdir -p /opt/actions-runner; \
    curl -fsSL -o /tmp/runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${version}/actions-runner-linux-x64-${version}.tar.gz"; \
    tar -xzf /tmp/runner.tar.gz -C /opt/actions-runner; \
    rm /tmp/runner.tar.gz; \
    /opt/actions-runner/bin/installdependencies.sh; \
    rm -rf /var/lib/apt/lists/*; \
    chown -R runner:runner /opt/actions-runner

# ── Re-point the root-installed toolchains at the runner user ────────────────
# The base image installs everything as root. Rust toolchains stay shared
# read-only under /root/.rustup (the rustup proxies in /root/.cargo/bin only
# read them); per-user writable state moves to /home/runner, where the named
# cache volumes mount (.pub-cache, .cargo/registry, go/pkg/mod — compose.yml).
# /root needs to be traversable for that; its contents are world-readable
# already (umask 022).
#
# /opt/flutter is chown'd outright: flutter takes bin/cache/lockfile on every
# invocation and downloads missing engine artifacts (e.g. the web SDK) on
# demand, so the SDK must be writable. This duplicates the SDK in this image
# layer — accepted cost; the image lives on the runner host, not a registry
# hot path.
ENV RUSTUP_HOME=/root/.rustup \
    CARGO_HOME=/home/runner/.cargo \
    GOPATH=/home/runner/go \
    PUB_CACHE=/home/runner/.pub-cache \
    PATH=/home/runner/.cargo/bin:/home/runner/go/bin:/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/usr/local/go/bin:/root/go/bin:/root/.cargo/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/usr/local/bin:/usr/bin:/bin
RUN set -eux; \
    chmod 755 /root; \
    chown -R runner:runner /opt/flutter; \
    git config --system --add safe.directory /opt/flutter; \
    mkdir -p /home/runner/.cargo/registry /home/runner/go/pkg/mod /home/runner/.pub-cache; \
    chown -R runner:runner /home/runner

# Per-user Flutter config for the runner account (analytics opt-out lives in
# $HOME); also proves the toolchain re-pointing works for the non-root user.
USER runner
RUN flutter config --no-analytics && flutter --version && go version && cargo --version
USER root

COPY entrypoint.sh /usr/local/bin/cepheus-runner-entrypoint
RUN chmod +x /usr/local/bin/cepheus-runner-entrypoint

WORKDIR /opt/actions-runner
# Starts as root (aligns the docker socket GID + cache volume ownership), then
# drops to the runner user for the register/run loop.
ENTRYPOINT ["/usr/local/bin/cepheus-runner-entrypoint"]
