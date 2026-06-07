#!/usr/bin/env bash
set -euo pipefail

compose_file="${PRINTDECK_COMPOSE_FILE:-${COMPOSE_FILE:-docker-compose.yml}}"
export COMPOSE_FILE="$compose_file"

if [[ -n "${PRINTDECK_COMPOSE_PROJECT_NAME:-}" ]]; then
  export COMPOSE_PROJECT_NAME="$PRINTDECK_COMPOSE_PROJECT_NAME"
fi

if [[ -n "${PRINTDECK_COMPOSE_PROFILES:-}" ]]; then
  export COMPOSE_PROFILES="$PRINTDECK_COMPOSE_PROFILES"
fi

if [[ -n "${PRINTDECK_COMPOSE_ENV_FILES:-}" ]]; then
  export COMPOSE_ENV_FILES="$PRINTDECK_COMPOSE_ENV_FILES"
fi

read_env_file_value() {
  local key="$1"
  local env_file="${PRINTDECK_ENV_FILE:-.env}"
  if [[ ! -f "$env_file" ]]; then
    return 0
  fi
  awk -v key="$key" '
    /^[[:space:]]*($|#)/ { next }
    {
      line = $0
      sub(/\r$/, "", line)
      sub(/^[[:space:]]*export[[:space:]]+/, "", line)
      split(line, parts, "=")
      name = parts[1]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name == key) {
        sub(/^[^=]*=/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if ((substr(line, 1, 1) == "\"" && substr(line, length(line), 1) == "\"") ||
            (substr(line, 1, 1) == "'"'"'" && substr(line, length(line), 1) == "'"'"'")) {
          line = substr(line, 2, length(line) - 2)
        }
        print line
        exit
      }
    }
  ' "$env_file"
}

if [[ -z "${CEPHEUS_READ_TOKEN:-}" ]]; then
  for key in GITHUB_PAT GH_TOKEN GITHUB_TOKEN; do
    value="${!key:-}"
    if [[ -z "$value" ]]; then
      value="$(read_env_file_value "$key")"
    fi
    if [[ -n "$value" ]]; then
      export CEPHEUS_READ_TOKEN="$value"
      break
    fi
  done
fi

if [[ -z "${CEPHEUS_READ_TOKEN:-}" ]] &&
   command -v gh >/dev/null 2>&1 &&
   gh auth status >/dev/null 2>&1; then
  export CEPHEUS_READ_TOKEN="$(gh auth token)"
fi

if [[ -z "${CEPHEUS_READ_TOKEN:-}" ]]; then
  echo "error: CEPHEUS_READ_TOKEN is required for private first-party Git dependencies." >&2
  echo "Set CEPHEUS_READ_TOKEN, provide GITHUB_PAT/GH_TOKEN/GITHUB_TOKEN, or authenticate gh on this host." >&2
  exit 2
fi

docker compose build --no-cache
docker compose up -d --remove-orphans
