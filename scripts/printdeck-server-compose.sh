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

docker compose build --no-cache
docker compose up -d --remove-orphans
