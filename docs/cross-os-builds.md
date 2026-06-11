# Cross-OS builds (`--execution-mode container`)

Build any product's targets for **any OS from any host** by routing each target
into a container or VM of the target's OS and re-invoking the same
`cepheus-build` there. It is the third execution mode, alongside `local`
(host-native) and `github` (dispatch a workflow).

## Why it works

Every target is host-gated on `current_host()` — a `macos` target only builds on
macOS, etc. This backend does not change that. It runs the *same* CLI inside the
matching OS, where `current_host()` already matches, so host gating, version
stamping, tool checks, and artifact globbing all behave exactly as a native
local build would. The backend only provides transport.

| Targets | Routed to |
|---|---|
| `web`, `android`, `linux`, `linux-deb`, `linux-appimage` (+ Go/Rust cross) | Linux container (`docker run`, no KVM) |
| `windows`, `windows-msix` | dockur/windows VM over SSH |
| `macos`, `macos-dmg`, `macos-appstore`, `ios` | dockur/macos VM over SSH |

Targets that allow several hosts (e.g. `web`) route to **linux** (cheapest).

## Topology

```
 Dispatch host (any OS)                    Remote Linux host (bare-metal, /dev/kvm)
 cepheus-build build \                     docker compose up -d  (docker/compose.yml)
   --execution-mode container               ├─ cbuild-windows  dockur/windows  :2322→22
   ├─ linux  → docker run (local) ─┐        └─ cbuild-macos    dockur/macos    :2422→22
   ├─ windows → rsync+ssh ─────────┼──────▶ cbuild-windows
   └─ macos   → rsync+ssh ─────────┼──────▶ cbuild-macos
```

The dockur Windows/macOS images run a full QEMU/KVM VM and **require `/dev/kvm`**,
so they live on a bare-metal Linux host. The Linux build image needs no KVM and
can run on the dispatch host itself (including a Windows/WSL2 laptop).

> **Note:** Docker Desktop on WSL2 does **not** expose `/dev/kvm` by default, so
> the macOS/Windows VMs cannot run on a Windows laptop — only Linux/Android/Web
> build locally there, and the rest dispatch to the remote KVM host over SSH.

## Profiles

Endpoints live in `build.toml` under `[container_profiles.<name>]`. Each host key
selects where that OS's targets build:

```toml
[container_profiles.default]
label = "Container/VM pool"
linux   = { kind = "docker", image = "ghcr.io/cepheuslabs/cepheus-build-linux:latest", workdir = "/work" }
windows = { kind = "ssh", host = "192.168.0.98", port = 2322, user = "cbuild", remote_root = "~/cbuild", toolkit = "~/cepheus-build", shell = "powershell" }
macos   = { kind = "ssh", host = "192.168.0.98", port = 2422, user = "cbuild", remote_root = "~/cbuild", toolkit = "~/cepheus-build", shell = "posix" }
```

Endpoint keys:

| key | docker | ssh | meaning |
|---|---|---|---|
| `kind` | ✓ | ✓ | `"docker"` or `"ssh"` |
| `image` | ✓ | — | Linux build image to `docker run` |
| `workdir` | ✓ | — | in-container mount point (default `/work`) |
| `host` / `user` / `port` | — | ✓ | how to reach the VM over SSH |
| `remote_root` | — | ✓ | where the repo is rsync'd (default `~/cbuild`) |
| `toolkit` | — | ✓ | path to the `cepheus-build` checkout in the VM |
| `shell` | — | ✓ | `"posix"` (macOS, or a Git-Bash Windows) or `"powershell"` |
| `launcher` | optional | optional | override how the CLI is invoked |
| `run_args` | optional | — | extra `docker run` flags |
| `rsync_ssh` | — | optional | ssh binary for rsync's `-e` transport (see Windows note below) |

`--container-profile <name>` selects a profile; `--container-host <h>` overrides
the host of every **ssh** endpoint. A docker endpoint always runs against the
**local** engine — it bind-mounts dispatch-host paths, which would resolve on
the wrong filesystem on a remote engine, so a configured `host` on a docker
endpoint is rejected (route Linux builds to another machine with `kind = "ssh"`
instead).

## Setup

1. **Build the Linux image** and make it pullable (or build it on each dispatch
   host): `docker compose --profile build-image build linux`.
2. **Stand up the VM pool**: `cepheus-build vm up --wait`. It runs
   `docker compose up -d` on the KVM host configured under
   `[container_profiles.<name>.compose]` (over ssh; or locally when no
   `compose.host` is set), then polls each VM's SSH endpoint until it accepts
   a connection. First boot installs the OS — watch the noVNC viewers and
   provision each VM once (see [../docker/README.md](../docker/README.md)).
   `cepheus-build vm status` shows compose state + SSH reachability;
   `cepheus-build vm down` powers the VMs off (compose stop, disks persist).
3. **Point the profile** at the VMs (`host`/`port`), add your SSH public key to
   each VM, and clone `cepheus-build` to the `toolkit` path inside each VM.

The container backend **fail-fasts** before dispatching: docker-kind groups
need a running docker engine, ssh-kind groups need `ssh` and `rsync` on the
dispatch host's PATH (skipped for `--dry-run` / `--no-check-tools`). The
`kvm` tool check only matters on the KVM host itself.

## Use

```bash
# Preview the exact docker/rsync/ssh commands without running anything:
cepheus-build build -p printdeck-app all --execution-mode container --dry-run

# Build everything, each target on the right OS:
cepheus-build build -p printdeck-app all --execution-mode container

# Just the desktop trio:
cepheus-build build -p printdeck-app macos windows linux --execution-mode container
```

OS host groups dispatch **in parallel** by default (the Linux container builds
while both VMs build), each output line prefixed `[linux] ` / `[macos] ` /
`[windows] `. Dispatch turns sequential (unprefixed) with `--no-parallel-hosts`,
under `--dry-run` (a preview should read top-to-bottom), or with
`--no-keep-going` (abort-on-first-failure needs an order).

Artifacts always end up in the **host** product repo: the docker path
bind-mounts it, and the ssh path rsyncs each target's **declared artifact
paths** back after the build (the glob-free prefix of every `artifacts`
entry — `build/...`, `dist/...`, `packaging/*/dist/...`, `target/...`), so
the normal `cepheus-build artifacts -p <product> <targets> --copy-to dist/`
step works unchanged.

> **Dispatch works from any host shell.** Transport commands (docker / ssh /
> rsync) are executed argv-style with no local shell in between, so the remote
> command reaches `ssh` as a single argument — including from native Windows.
> The dispatch host only needs `ssh` and `rsync` on `PATH` (`rsync` is not part
> of Git for Windows: install it via MSYS2 `pacman -S rsync`, `choco install
> rsync`, or dispatch from WSL).
>
> **Windows dispatch + rsync caveat:** an MSYS2/Cygwin rsync cannot drive the
> native Win32-OpenSSH `ssh.exe` (incompatible pipe handling). Set
> `rsync_ssh = "C:/msys64/usr/bin/ssh.exe"` (or your cwRsync's bundled ssh) on
> the ssh endpoints so rsync's `-e` transport uses a matching ssh; the plain
> `ssh` steps keep using the native client.

## Dependencies, stamping, and secrets

- **First-party deps** resolve from **committed pins** (forge git ref, Go
  pseudo-versions), exactly like CI — *not* the local `deps --write` overrides.
  `GOWORK=off` is set; `pubspec_overrides.yaml` / `go.work` are excluded from the
  rsync (and warned about for a bind-mounted Flutter tree). Remove them for a
  clean container build, or commit the pins you want.
- **Version stamp** is computed once on the dispatch host (where `.git` is
  intact) and injected as `CBUILD_VERSION` / `CBUILD_BUILD_NUMBER`, so every OS
  in one run shares the same stamp.
- **dart_define env vars** referenced by `[flutter.dart_defines]` are forwarded
  when set on the dispatch host; unset ones fall back to their declared default.
- **Private git pins** (forge/slicer/nexus/... by https ref) need read access
  inside the container/VM at `pub get` / `go mod` time. Set
  `CEPHEUS_READ_TOKEN` on the dispatch host (e.g.
  `CEPHEUS_READ_TOKEN=$(gh auth token)`): it is forwarded as a secret
  (name-only to docker, redacted from echoed ssh commands) and the inner
  build turns it into **ephemeral** git config-from-env auth plus `GOPRIVATE`
  — nothing is written to any .gitconfig or credential store.

## Security / trust boundary

Product TOML `commands` are trusted input and now also execute **inside the
VMs** over SSH. Only expose the VMs to hosts you control, use **key-based SSH
auth**, and keep the pool on a private network. This is the same trust model as
local builds — see the README's "Security / Trust Boundary" section.

Host keys are **trust-on-first-use**: every transport ssh/rsync runs with
`StrictHostKeyChecking=accept-new` and `BatchMode=yes` (no interactive
prompts; key auth only). A fresh VM's key is recorded automatically, but a
*changed* key — e.g. after a VM reinstall — still fails loudly; remove the old
entry from `~/.ssh/known_hosts` to re-trust. Forwarded `dart_define` env
values are treated as secrets: the docker path passes them name-only and the
ssh path redacts them from echoed commands, so they never land in GUI/CI logs.

## macOS licensing

Apple's macOS Software License Agreement permits virtualization only on
Apple-branded hardware. Running `dockur/macos` on non-Apple hardware is outside
that license; proceed at your discretion. macOS/iOS store signing and
notarization require Apple Developer certificates supplied as env/secret files
at build time.
