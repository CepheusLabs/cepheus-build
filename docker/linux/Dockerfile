# Cepheus Build — Linux build image.
#
# The workhorse of the container execution backend: builds web, android, linux,
# linux-deb, linux-appimage (and cross-compiles Go/Rust) with no KVM. The
# container backend bind-mounts the product repo at /work and this toolkit at
# /opt/cepheus-build, then runs `cepheus-build build ... --execution-mode local`.
#
# Ubuntu base (NOT alpine): Flutter Linux desktop needs glibc + GTK.
# Versions track the ecosystem standard (Go 1.26.x, Rust 1.95, Python 3.12).
FROM ubuntu:24.04

ARG GO_VERSION=1.26.4
ARG RUST_VERSION=1.95.0
# Tracks the dev machines (3.41.x stable): product Makefiles use flags that
# do not exist in older SDKs (e.g. `flutter build web --no-wasm-dry-run`).
ARG FLUTTER_VERSION=3.41.7
ARG ANDROID_SDK_TOOLS=11076708
ARG ANDROID_PLATFORM=android-35
ARG ANDROID_BUILD_TOOLS=35.0.0
ARG ANDROID_NDK=27.0.12077973

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    GOPATH=/root/go \
    GOWORK=off \
    PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/usr/local/go/bin:/root/go/bin:/root/.cargo/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/usr/local/bin:/usr/bin:/bin

# ── System + Flutter Linux-desktop + packaging toolchains ───────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git unzip zip xz-utils \
        bash make cmake ninja-build clang pkg-config file \
        libgtk-3-dev liblzma-dev libstdc++-12-dev libsecret-1-dev \
        openssh-client rsync sudo \
        openjdk-17-jdk-headless \
        dpkg-dev rpm fakeroot \
        flatpak flatpak-builder \
        python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# appimagetool (no apt package) — used by the linux-appimage target.
RUN wget -qO /usr/local/bin/appimagetool \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage" \
    && chmod +x /usr/local/bin/appimagetool

# ── Go ──────────────────────────────────────────────────────────────────────
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
        | tar -C /usr/local -xz \
    && go version

# ── Rust (pinned) + cargo-ndk for Android NDK cross-builds ──────────────────
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain "${RUST_VERSION}" --profile minimal \
    && . /root/.cargo/env \
    && rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android \
    && cargo install cargo-ndk --locked \
    && rustc --version

# ── Android SDK (cmdline-tools, platform, build-tools, NDK) ──────────────────
RUN mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools" \
    && curl -fsSL -o /tmp/cmdline-tools.zip \
        "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_SDK_TOOLS}_latest.zip" \
    && unzip -q /tmp/cmdline-tools.zip -d "${ANDROID_SDK_ROOT}/cmdline-tools" \
    && mv "${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools" "${ANDROID_SDK_ROOT}/cmdline-tools/latest" \
    && rm /tmp/cmdline-tools.zip \
    && yes | sdkmanager --licenses >/dev/null \
    && sdkmanager --install "platform-tools" \
        "platforms;${ANDROID_PLATFORM}" \
        "build-tools;${ANDROID_BUILD_TOOLS}" \
        "ndk;${ANDROID_NDK}" >/dev/null

# ── Flutter (pinned stable) ─────────────────────────────────────────────────
RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git /opt/flutter \
    && git config --global --add safe.directory /opt/flutter \
    && flutter config --no-analytics \
    && flutter config --enable-linux-desktop --enable-android \
    && flutter precache --linux --android --universal \
    && flutter --version

# Auto-update EdDSA key tooling used by some packaging/publish scripts.
RUN python3 -m pip install --break-system-packages --no-cache-dir pynacl

COPY entrypoint.sh /usr/local/bin/cepheus-entrypoint
RUN chmod +x /usr/local/bin/cepheus-entrypoint

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/cepheus-entrypoint"]
CMD ["flutter", "doctor", "-v"]
