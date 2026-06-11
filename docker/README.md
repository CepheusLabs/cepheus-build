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

## 1. Build the Linux image (any host)

```bash
docker compose --profile build-image build linux
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
macOS `http://<host>:8406`. First boot is slow.

- **Windows** auto-installs, then runs `windows/oem/install.bat` (OpenSSH + the
  build toolchain). After it finishes, add your SSH key to
  `C:\ProgramData\ssh\administrators_authorized_keys` and clone the
  `cepheus-build` toolkit to `%USERPROFILE%\cepheus-build`.
- **macOS** needs the setup wizard completed manually, then enable **Remote
  Login**, add your SSH key to `~/.ssh/authorized_keys`, and run
  `macos/provision.sh` (Homebrew, Flutter, CocoaPods, Go, Rust). Install Xcode
  separately, and clone `cepheus-build` to `~/cepheus-build`.

## 3. Point the profile at the pool

Edit `build.toml [container_profiles.default]` so `windows`/`macos` `host`/`port`
match where these VMs are reachable (the host's IP + the published `2322`/`2422`).

Then, from any dispatch host:

```bash
cepheus-build build -p printdeck-app windows macos --execution-mode container
```

Full walkthrough + security notes: [../docs/cross-os-builds.md](../docs/cross-os-builds.md).
