#!/usr/bin/env bash
# ===========================================================================
# Cepheus Build — macOS VM provisioning.
#
# Unlike Windows, dockur/macos has NO unattended install: complete the macOS
# setup wizard once via the web viewer (http://<kvm-host>:8406), create the
# `cbuild` user, then enable Remote Login:
#
#   System Settings ▸ General ▸ Sharing ▸ Remote Login = ON
#
# Then copy your dispatch host's SSH public key into ~cbuild/.ssh/authorized_keys
# and run this script INSIDE the VM (over SSH or in Terminal):
#
#   curl -fsSL <raw-url>/provision.sh | bash      # or scp it in and run
#
# It installs Homebrew, Flutter, CocoaPods, Rust, and Go. Xcode itself is a
# large manual step: install it from the App Store (or `xcodes`), then run
#   sudo xcodebuild -license accept
#   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
#
# Apple's macOS license permits virtualization only on Apple-branded hardware;
# running this on non-Apple hardware is your call. Store signing/notarization
# needs Apple Developer certificates supplied as env/secret files at build time.
# ===========================================================================
set -euo pipefail
echo "[cepheus] provisioning macOS build VM..."

# --- Toolchain pins -------------------------------------------------------
# Single source of truth: docker/versions.env (sibling of this script's parent
# dir). Every provisioner reads it so the whole pool installs the same Go/
# Rust/CocoaPods/Python/Flutter; CI asserts these stay in sync with the Linux
# Dockerfile ARGs.
source "$(cd "$(dirname "$0")"/.. && pwd)/versions.env"

# --- Homebrew -------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"

# --- Flutter (PINNED to match the whole pool) -----------------------------
# Must equal docker/linux/Dockerfile's FLUTTER_VERSION: a brew --cask flutter
# installs LATEST, which drifts ahead of the Linux builder and breaks shared
# code (e.g. forge using APIs a newer Flutter removed). Git-clone the exact
# tag, the same mechanism the Linux image uses, so every OS builds identically.
FLUTTER_VERSION="${CBUILD_FLUTTER_VERSION:-3.41.7}"
brew uninstall --cask flutter 2>/dev/null || true   # drop any unpinned/latest flutter
_have=""
[ -x "$HOME/flutter/bin/flutter" ] && _have="$("$HOME/flutter/bin/flutter" --version 2>/dev/null | sed -n 's/^Flutter \([0-9.][0-9.]*\).*/\1/p')"
if [ "$_have" != "$FLUTTER_VERSION" ]; then
  rm -rf "$HOME/flutter"
  git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$HOME/flutter"
fi
grep -q 'flutter/bin' "$HOME/.zshenv" 2>/dev/null \
  || echo 'export PATH="$HOME/flutter/bin:$PATH"' >> "$HOME/.zshenv"
export PATH="$HOME/flutter/bin:$PATH"

# --- Other toolchains -----------------------------------------------------
# python@3.12: the Xcode CLT python3 is 3.9, too old for the toolkit
# (tomllib needs >= 3.11). Homebrew does not link an unversioned python3,
# and non-interactive ssh shells skip path_helper, so both get fixed here.
# Go and CocoaPods are NOT brewed (brew installs LATEST and drifts ahead of
# the rest of the pool); they are pinned below. create-dmg has no inherent
# version risk (a fixed DMG layout tool) so it stays on brew's latest.
brew install create-dmg "python@${CBUILD_PYTHON_VERSION}"
ln -sf "$(brew --prefix)/bin/python${CBUILD_PYTHON_VERSION}" "$(brew --prefix)/bin/python3"
grep -q "/usr/local/bin" "$HOME/.zshenv" 2>/dev/null \
  || echo 'export PATH=/usr/local/bin:$PATH' >> "$HOME/.zshenv"

# --- Go (PINNED — same mechanism as the Flutter git-clone) ----------------
# brew go floats to latest; download the exact tarball to a fixed dir + PATH
# so macOS matches docker/linux/Dockerfile's GO_VERSION.
GO_ROOT="$HOME/go-sdk/go${CBUILD_GO_VERSION}"
if [ ! -x "$GO_ROOT/bin/go" ]; then
  rm -rf "$HOME/go-sdk" && mkdir -p "$HOME/go-sdk"
  curl -fsSL "https://go.dev/dl/go${CBUILD_GO_VERSION}.darwin-arm64.tar.gz" \
    | tar -C "$HOME/go-sdk" -xz
  mv "$HOME/go-sdk/go" "$GO_ROOT"
fi
grep -q 'go-sdk/go' "$HOME/.zshenv" 2>/dev/null \
  || echo "export PATH=\"$GO_ROOT/bin:\$PATH\"" >> "$HOME/.zshenv"
export PATH="$GO_ROOT/bin:$PATH"

# --- Rust via rustup (pinned to the ecosystem standard) -------------------
if ! command -v rustup >/dev/null 2>&1; then
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain "$CBUILD_RUST_VERSION" --profile minimal
fi

# --- CocoaPods (PINNED via gem; brew cocoapods floats to latest) ----------
gem install cocoapods -v "$CBUILD_COCOAPODS_VERSION"

# --- pynacl (build.toml [tools.python3] check does `import nacl`) ----------
python3 -m pip install --break-system-packages pynacl 2>/dev/null || pip3 install pynacl

flutter config --no-analytics
flutter config --enable-macos-desktop --enable-ios
flutter precache --macos --ios

# --- Verify the pinned toolchains actually resolve ------------------------
go version
pod --version
python3 -c "import nacl"

echo "[cepheus] toolchains installed."
echo "[cepheus] NEXT: install Xcode (App Store / xcodes), accept its license,"
echo "          and clone cepheus-build to ~/cepheus-build (build.toml toolkit path)."
