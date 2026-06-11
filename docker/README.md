# Cross-OS build pool (`docker/`)

Assets for the `--execution-mode container` backend: a Linux build image plus
two dockur KVM VMs (Windows + macOS). The VMs build on a **remote Linux host
with real `/dev/kvm`** (e.g. errai); the Linux image needs no KVM and can run
anywhere, including a Windows/WSL2 laptop.

```
docker/
  compose.yml            # windows + macos dockur VMs (+ the linux build-image stage)
  linux/Dockerfile       # Flutter + Android + Go + Rust + linux packaging
  linux/entrypoint.sh
  windows/oem/install.bat# dockur runs this automatically after Windows installs
  macos/provision.sh     # run manually inside the macOS VM after first-boot setup
```

## 0. One-time KVM host prep

`vm up/down/status` drive compose **on the KVM host** (`[container_profiles.
<name>.compose]` in `build.toml`), against a `cepheus-build` checkout there:

```bash
ssh errai@192.168.0.98 git clone https://github.com/CepheusLabs/cepheus-build ~/cepheus-build
```

Before first boot, drop your dispatch host's SSH **public** key at
`docker/windows/oem/authorized_keys` in that checkout (git-ignored) —
`install.bat` installs it and disables password auth on the Windows VM.

## 1. Build the Linux image (any host)

```bash
docker compose -f docker/compose.yml --profile build-image build linux
# or directly:
docker build -t ghcr.io/cepheuslabs/cepheus-build-linux:latest docker/linux
```

Push it to a registry the dispatch hosts can pull, or build it locally on each
dispatch host. The image name must match
`build.toml [container_profiles.default.linux].image`.

## 2. Start the VM pool

From any dispatch host (uses `[container_profiles.<name>.compose]` to reach
the KVM host over ssh):

```bash
cepheus-build vm up --wait     # compose up -d + poll SSH endpoints
cepheus-build vm status        # compose ps + one SSH probe per VM
cepheus-build vm down          # power off (compose stop; VM disks persist)
```

Or manually on the KVM host itself:

```bash
test -e /dev/kvm || echo "NO KVM — dockur VMs cannot boot here"
cd docker && docker compose up -d windows macos
```

Watch each install via the web viewer: Windows `http://<host>:8306`,
macOS `http://<host>:8406`. First boot is slow. The viewer is
**unauthenticated** and SSH starts with password auth: keep the pool on a
trusted LAN, or set `CBUILD_VM_BIND=127.0.0.1` on the KVM host and reach the
ports through an SSH tunnel.

- **Windows** auto-installs, then runs `windows/oem/install.bat` (OpenSSH, the
  build toolchain, **rsync** — required VM-side by the repo push/artifact
  pull — and your seeded SSH key, if provided). Afterwards clone the
  `cepheus-build` toolkit to `%USERPROFILE%\cepheus-build` (and add your key
  manually if it was not seeded).
- **macOS** needs the setup wizard completed manually, then enable **Remote
  Login**, add your SSH key to `~/.ssh/authorized_keys`, and run
  `macos/provision.sh` (Homebrew, Flutter, CocoaPods, Go, Rust; the stock
  macOS rsync is sufficient). Install Xcode separately, and clone
  `cepheus-build` to `~/cepheus-build`.

## 3. Point the profile at the pool

Edit `build.toml [container_profiles.default]` so `windows`/`macos` `host`/`port`
match where these VMs are reachable (the host's IP + the published `2322`/`2422`).

Then, from any dispatch host:

```bash
cepheus-build build -p printdeck-app windows macos --execution-mode container
```

Full walkthrough + security notes: [../docs/cross-os-builds.md](../docs/cross-os-builds.md).
