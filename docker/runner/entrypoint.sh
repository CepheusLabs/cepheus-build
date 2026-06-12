#!/usr/bin/env bash
# Cepheus Build — ephemeral GitHub Actions runner entrypoint (first-party).
#
# Registers an EPHEMERAL org-scoped runner against https://github.com/<org>
# and re-registers in an endless loop: `--ephemeral` deregisters the runner
# after exactly one job, so every job starts on a freshly registered runner
# while the container (toolchains + mounted caches) persists. Auto-
# re-registering ephemeral pattern per the release-pipeline plan (Phase 1.1,
# locked decision L6).
#
# Required env (from .env.runner — see README.md):
#   GH_RUNNER_PAT       org-admin PAT (scope: admin:org). Used ONLY to mint
#                       short-lived registration/removal tokens via the GitHub
#                       API; never written to disk. Moved into an UNEXPORTED
#                       shell variable at the start of the runner phase, so no
#                       child process — config.sh, run.sh, and therefore no
#                       workflow job step — ever inherits it.
# Optional env:
#   RUNNER_ORG          GitHub org (default: CepheusLabs)
#   RUNNER_LABELS       comma-separated labels (default: self-hosted,linux)
#   RUNNER_NAME_PREFIX  runner name prefix (default: cbuild-linux); the
#                       container hostname is appended for uniqueness
#   RUNNER_GROUP        runner group (default: Default)
#   RUNNER_RETRY_DELAY  seconds between loop iterations (default: 5)
#   RUNNER_MAX_REGISTER_FAILURES
#                       consecutive registration failures before exiting 1
#                       instead of spinning forever (default: 12; an expired/
#                       revoked PAT trips this — the compose restart policy
#                       and fleet monitoring take it from there)
set -euo pipefail

ORG="${RUNNER_ORG:-CepheusLabs}"
LABELS="${RUNNER_LABELS:-self-hosted,linux}"
NAME="${RUNNER_NAME_PREFIX:-cbuild-linux}-$(hostname)"
GROUP="${RUNNER_GROUP:-Default}"
RETRY_DELAY="${RUNNER_RETRY_DELAY:-5}"
RUNNER_DIR=/opt/actions-runner

if [ -z "${GH_RUNNER_PAT:-}" ]; then
  echo "fatal: GH_RUNNER_PAT is not set (org-admin PAT, scope admin:org). See docker/runner/README.md." >&2
  exit 1
fi

# ── Root phase: align docker socket access + cache ownership, then drop ──────
if [ "$(id -u)" = "0" ]; then
  if [ -S /var/run/docker.sock ]; then
    sock_gid="$(stat -c %g /var/run/docker.sock)"
    sock_group="$(getent group "$sock_gid" | cut -d: -f1 || true)"
    if [ -z "$sock_group" ]; then
      # No group has the socket's GID yet: move our `docker` group onto it.
      groupmod -g "$sock_gid" docker
      sock_group=docker
    fi
    usermod -aG "$sock_group" runner
  fi
  # Named cache volumes mount root-owned on first use.
  for dir in /home/runner/.pub-cache /home/runner/.cargo/registry /home/runner/go/pkg/mod; do
    mkdir -p "$dir"
    chown runner:runner "$dir"
  done
  # setpriv (not su/runuser): preserves the environment — including
  # GH_RUNNER_PAT and the toolchain ENV from the Dockerfile — and picks up the
  # supplementary groups just granted (docker).
  exec setpriv --reuid=runner --regid=runner --init-groups \
    env HOME=/home/runner USER=runner LOGNAME=runner "$0" "$@"
fi

# ── Runner phase: register-ephemeral / run / repeat ──────────────────────────
cd "$RUNNER_DIR"

# Secret hygiene (HIGH): hold the PAT in an UNEXPORTED shell variable and drop
# it from the exported environment before anything else runs, so no child
# process — config.sh, run.sh, and therefore no workflow job step — ever
# inherits it. Only the per-call `GH_TOKEN=...` prefix on `gh api` sees it;
# the EXIT cleanup still reaches it through this shell variable.
pat="$GH_RUNNER_PAT"
unset GH_RUNNER_PAT

fetch_token() {
  # $1: registration-token | remove-token
  # POST /orgs/{org}/actions/runners/{registration-token|remove-token}
  GH_TOKEN="$pat" gh api -X POST "orgs/${ORG}/actions/runners/$1" --jq .token
}

shutdown=0
run_pid=""
on_term() {
  shutdown=1
  if [ -n "$run_pid" ]; then
    kill -TERM "$run_pid" 2>/dev/null || true
  fi
}
trap on_term TERM INT

cleanup() {
  # Stopped between registration and job pickup: remove the server-side
  # registration so no ghost runner lingers in the org.
  if [ -f .runner ]; then
    echo "entrypoint: removing runner registration for ${NAME}"
    ./config.sh remove --token "$(fetch_token remove-token)" || true
  fi
}
trap cleanup EXIT

# Bounded registration retries: transient API/network blips ride through, but
# a persistent failure (expired/revoked PAT) exits 1 instead of spinning.
failures=0
max_failures="${RUNNER_MAX_REGISTER_FAILURES:-12}"
register_failed() {
  failures=$((failures + 1))
  if [ "$failures" -ge "$max_failures" ]; then
    echo "fatal: ${failures} consecutive registration failures (expired/revoked GH_RUNNER_PAT? org unreachable?); giving up." >&2
    exit 1
  fi
  echo "entrypoint: registration failed (${failures}/${max_failures}); retrying in ${RETRY_DELAY}s" >&2
  sleep "${RETRY_DELAY}"
}

while [ "$shutdown" -eq 0 ]; do
  # An ephemeral runner's server-side registration is consumed by its one job;
  # drop the stale local credentials before re-configuring.
  rm -f .runner .credentials .credentials_rsaparams

  echo "entrypoint: registering ephemeral runner ${NAME} (org: ${ORG}, labels: ${LABELS})"
  if ! reg_token="$(fetch_token registration-token)"; then
    register_failed
    continue
  fi
  if ! ./config.sh \
      --url "https://github.com/${ORG}" \
      --token "$reg_token" \
      --name "${NAME}" \
      --runnergroup "${GROUP}" \
      --no-default-labels \
      --labels "${LABELS}" \
      --work _work \
      --ephemeral \
      --unattended \
      --replace; then
    register_failed
    continue
  fi
  failures=0

  # A SIGTERM that landed during registration must not start a job: bail out
  # here and let the EXIT cleanup remove the registration just created.
  if [ "$shutdown" -ne 0 ]; then
    break
  fi

  # Background + wait so the TERM/INT trap can forward the signal to run.sh
  # (the runner finishes its in-flight job on SIGTERM, then exits).
  ./run.sh &
  run_pid=$!
  wait "$run_pid" || true
  run_pid=""

  if [ "$shutdown" -eq 0 ]; then
    echo "entrypoint: runner exited; re-registering in ${RETRY_DELAY}s"
    sleep "${RETRY_DELAY}"
  fi
done

echo "entrypoint: shutdown requested; exiting"
