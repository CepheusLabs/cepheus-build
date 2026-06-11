# GitHub Actions runner fleet (`docker/runner/`)

First-party Linux runner image for the release pipeline (plan Phase 1.1/1.2,
locked decision L6). Builds `FROM ghcr.io/cepheuslabs/cepheus-build-linux:latest`
(the proven container-backend toolchain image) and adds the GitHub Actions
runner plus the docker and gh CLIs.

Properties:

- **Org-scoped, ephemeral, auto-re-registering.** The entrypoint mints a
  short-lived registration token from the GitHub API at start, registers with
  `--ephemeral --unattended`, runs exactly one job, then loops and re-registers.
  Each job gets a pristine runner; the container and its caches persist.
- **Labels exactly `self-hosted,linux`** (`--no-default-labels`), matching
  `build.toml [github.runner_profiles.self-hosted]`. No bespoke labels.
- **Dedicated non-root `runner` user** with passwordless sudo (workflow steps
  run `sudo apt-get`), docker socket access via a GID-aligned `docker` group.
- **Named cache volumes** `cbuild-pub-cache`, `cbuild-cargo-registry`,
  `cbuild-go-mod` mounted at the runner user's cache paths, shared across
  replicas and registrations.

## 1. PAT (one-time, org admin)

Mint a classic PAT with scope **`admin:org`** (it is used only to call
`POST /orgs/CepheusLabs/actions/runners/registration-token` and
`.../remove-token`; the short-lived tokens it mints are what actually register
runners). A fine-grained PAT with org permission
"Self-hosted runners: Read and write" also works.

The PAT lives **only** in `.env.runner` on the runner host — never in images,
never in the repo, never in GitHub secrets.

## 2. `.env.runner` on errai

Canonical location (root-readable only, alongside the other prod env files):

```bash
sudo install -m 600 -o root -g root /dev/stdin /media/cl-webapp/printdeck/.env.runner <<'EOF'
GH_RUNNER_PAT=ghp_...
EOF
```

`compose.yml` reads `./.env.runner` relative to this directory, so symlink it
into the checkout on errai (the symlink target stays root-only; run compose
with sudo):

```bash
ln -sf /media/cl-webapp/printdeck/.env.runner ~/cepheus-build/docker/runner/.env.runner
```

`.env.runner` is git-ignored — it must never be committed.

## 3. Build + run

```bash
cd ~/cepheus-build/docker/runner
sudo docker compose up -d --build --scale github-runner=2
```

`--scale github-runner=2` is the standing fleet size on errai. Resource limits
default to 4 CPUs / 12g per replica; override with `CBUILD_RUNNER_CPUS` /
`CBUILD_RUNNER_MEM` on the compose invocation.

Verify registration (runners appear/disappear per job — ephemeral):

```bash
gh api orgs/CepheusLabs/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

## 4. Operations

- **Update the runner version:** runner auto-update is ON; rebuild the image
  (`--build`) only to refresh the baked toolchains or pin via
  `--build-arg RUNNER_VERSION=x.y.z`.
- **Stop:** `sudo docker compose down`. The entrypoint traps SIGTERM, lets an
  in-flight job finish, and removes any unconsumed registration on exit.
- **Retire the old repo-scoped printdeck-server runner** once this fleet is
  live (plan Phase 1.2) — it used the bespoke `printdeck` label.
- The docker socket mount means jobs can drive the host daemon; the runner
  group restricts these runners to private org repos (GitHub default).
