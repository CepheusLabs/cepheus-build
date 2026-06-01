# shellcheck shell=sh
# rustup-resolve.sh — resolve cargo + rustc via rustup and export RUSTC.
#
# This is the load-bearing toolchain-resolution workaround shared by the macOS
# and iOS "Build Rust Core" Xcode run-script phases. Both Anvil and Colorwake
# carry it verbatim and BOTH apps' CLAUDE.md explicitly say it is deliberate and
# must NOT be "simplified" — so it lives here once and is sourced, byte-for-byte,
# by every embed script. Do not collapse it to a bare `cargo`/`rustup run`.
#
# WHY (from anvil/app/macos/rust_core_build.sh):
#   Xcode's build environment does not inherit the interactive shell PATH, so
#   rustup/cargo at ~/.cargo/bin are not on PATH. We locate rustup first, then
#   pin cargo AND rustc to the rustup-managed toolchain (the one
#   rust-toolchain.toml selects). This is critical: a Homebrew rust typically
#   sits ahead of ~/.cargo/bin on PATH, so cargo would otherwise invoke `rustc`
#   by bare name and pick up the Homebrew rustc — whose sysroot ships only the
#   host std. The x86_64 slice of the universal build then fails with "can't
#   find crate for core" even though the rustup toolchain has the target
#   installed. Resolving both binaries via `rustup which` and exporting RUSTC
#   makes the toolchain unambiguous.
#
# CONTRACT: this is a POSIX-sh fragment meant to be `.`-sourced (not executed).
# It is side-effecting by design:
#   * exports RUSTC          (when a rustup-managed rustc is found)
#   * sets   RUSTUP          (path to the rustup binary, or empty)
#   * sets   CARGO           (path to the cargo binary to invoke)
#   The caller then runs "${CARGO}" build ... and may use "${RUSTUP}" to
#   `rustup target add` per-arch std (idempotent). If cargo cannot be found the
#   fragment prints an error to stderr and `exit 1`s the calling script.
#
# This fragment names NO crate, app, or product — it is pure toolchain plumbing
# and is identical for every consumer (the one-way rule: shared code never names
# an engine crate).

# Xcode's build environment does not inherit the interactive shell PATH, so
# rustup/cargo at ~/.cargo/bin are not on PATH. Locate rustup first.
RUSTUP="$(command -v rustup 2>/dev/null || true)"
if [ -z "${RUSTUP}" ] && [ -x "${HOME}/.cargo/bin/rustup" ]; then
  RUSTUP="${HOME}/.cargo/bin/rustup"
fi

# Pin cargo AND rustc to the rustup-managed toolchain (the one rust-toolchain.toml
# selects). This is critical: a Homebrew rust typically sits ahead of ~/.cargo/bin
# on PATH, so cargo would otherwise invoke `rustc` by bare name and pick up the
# Homebrew rustc — whose sysroot ships only the host std. The x86_64 slice of the
# universal build then fails with "can't find crate for core" even though the
# rustup toolchain has the target installed. Resolving both binaries via
# `rustup which` and exporting RUSTC makes the toolchain unambiguous.
CARGO="${CARGO:-}"
if [ -n "${RUSTUP}" ]; then
  CARGO="$("${RUSTUP}" which cargo 2>/dev/null || true)"
  RUSTC="$("${RUSTUP}" which rustc 2>/dev/null || true)"
  if [ -n "${RUSTC}" ]; then
    export RUSTC
  fi
fi
if [ -z "${CARGO}" ]; then
  CARGO="$(command -v cargo 2>/dev/null || true)"
fi
if [ -z "${CARGO}" ] && [ -x "${HOME}/.cargo/bin/cargo" ]; then
  CARGO="${HOME}/.cargo/bin/cargo"
fi
if [ -z "${CARGO}" ]; then
  echo "error: cargo not found. Install Rust from https://rustup.rs/ and ensure cargo is on PATH or at ~/.cargo/bin/cargo." >&2
  exit 1
fi
