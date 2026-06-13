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
brew install cocoapods go create-dmg python@3.12
ln -sf "$(brew --prefix)/bin/python3.12" "$(brew --prefix)/bin/python3"
grep -q "/usr/local/bin" "$HOME/.zshenv" 2>/dev/null \
  || echo 'export PATH=/usr/local/bin:$PATH' >> "$HOME/.zshenv"
# Rust via rustup (pinned to the ecosystem standard).
if ! command -v rustup >/dev/null 2>&1; then
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.95.0 --profile minimal
fi

flutter config --no-analytics
flutter config --enable-macos-desktop --enable-ios
flutter precache --macos --ios

echo "[cepheus] toolchains installed."
echo "[cepheus] NEXT: install Xcode (App Store / xcodes), accept its license,"
echo "          and clone cepheus-build to ~/cepheus-build (build.toml toolkit path)."
