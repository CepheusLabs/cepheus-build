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

`--container-profile <name>` selects a profile; `--container-host <h>` overrides
the host/endpoint of every entry (handy for a one-off remote engine).

## Setup

1. **Build the Linux image** and make it pullable (or build it on each dispatch
   host): `docker compose --profile build-image build linux`.
2. **Stand up the VM pool** on the KVM host: `cd docker && docker compose up -d
   windows macos`, then provision each VM (see [../docker/README.md](../docker/README.md)).
3. **Point the profile** at the VMs (`host`/`port`), add your SSH public key to
   each VM, and clone `cepheus-build` to the `toolkit` path inside each VM.

`cepheus-build doctor` reports the new `kvm` / `ssh` / `rsync` tools; `kvm` is
only meaningful on the KVM host.

## Use

```bash
# Preview the exact docker/rsync/ssh commands without running anything:
cepheus-build build -p printdeck-app all --execution-mode container --dry-run

# Build everything, each target on the right OS:
cepheus-build build -p printdeck-app all --execution-mode container

# Just the desktop trio:
cepheus-build build -p printdeck-app macos windows linux --execution-mode container
```

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
> rsync`, or dispatch from WSL). `cepheus-build doctor` checks both.

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

## Security / trust boundary

Product TOML `commands` are trusted input and now also execute **inside the
VMs** over SSH. Only expose the VMs to hosts you control, use **key-based SSH
auth**, and keep the pool on a private network. This is the same trust model as
local builds — see the README's "Security / Trust Boundary" section.

## macOS licensing

Apple's macOS Software License Agreement permits virtualization only on
Apple-branded hardware. Running `dockur/macos` on non-Apple hardware is outside
that license; proceed at your discretion. macOS/iOS store signing and
notarization require Apple Developer certificates supplied as env/secret files
at build time.
