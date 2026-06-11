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

# --- Toolchains -----------------------------------------------------------
brew install --cask flutter
brew install cocoapods go create-dmg
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
