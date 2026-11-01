#!/usr/bin/env bash
# Isolated e2e server stack (Compose project `vd-e2e`), next to the prod stack.
#
#   up       build and start the stack; writes .env.e2e on first run
#   check    /health and the e2e bearer, over the tailnet IP
#   session  post a fixture session bundle and poll it to its end state
#   reset    drop and reseed the e2e DB (fixed fictional cast), clear Qdrant
#            and stored session bundles, restart the fixture upstreams
#   down     stop the stack and delete its containers, network and volumes
#
# Usage:
#     bash scripts/e2e_stack.sh up|check|session [client args]|reset|down
#
# Environment:
#     TAILNET_IP   used only when .env.e2e does not exist yet; default is
#                  `tailscale ip -4`
#
# Safety: every Compose call is `-p vd-e2e` with `--env-file .env.e2e`, so the
# prod `.env`, `data/msal_cache.bin` and the prod volumes are never read or
# touched, and `down -v` can only delete this project's volumes.
#
# Run from anywhere; the script changes into the repository's `server/`.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PROJECT="vd-e2e"
ENV_FILE=".env.e2e"
PORT=8100

# Compose's own interpolation prefers the shell over --env-file. Drop anything
# a prod session may have exported so only .env.e2e feeds this project.
STACK_TAILNET_IP="${TAILNET_IP:-}"
unset TAILNET_IP POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB IOS_BEARER_TOKEN \
  WHISPER_URL WHISPER_MODEL WHISPER_IMAGE_TAG WHISPER_ENGINE E2E_WHISPER_MODEL \
  VOXTRAL_BASE_URL VOXTRAL_MODEL VOXTRAL_TIMEOUT_SECONDS HF_TOKEN \
  HARVEST_ACCESS_TOKEN HARVEST_ACCOUNT_ID HARVEST_USER_ID

compose() {
  docker compose -p "$PROJECT" --env-file "$ENV_FILE" \
    -f docker-compose.yml -f docker-compose.e2e.yml "$@"
}

env_value() {
  grep -m1 "^$1=" "$ENV_FILE" | cut -d= -f2-
}

require_env() {
  if [ ! -f "$ENV_FILE" ]; then
    echo "! $ENV_FILE not found; run 'e2e_stack.sh up' first" >&2
    exit 1
  fi
}

write_env() {
  local ip="${STACK_TAILNET_IP:-}"
  if [ -z "$ip" ] && command -v tailscale >/dev/null 2>&1; then
    ip="$(tailscale ip -4 | head -n1)"
  fi
  if [ -z "$ip" ]; then
    echo "! Set TAILNET_IP to this host's Tailscale IPv4 (tailscale ip -4)" >&2
    exit 1
  fi
  umask 077
  sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
    -e "s|^TAILNET_IP=.*|TAILNET_IP=$ip|" \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(openssl rand -hex 32)|" \
    -e "s|^IOS_BEARER_TOKEN=.*|IOS_BEARER_TOKEN=$(openssl rand -hex 32)|" \
    .env.e2e.example > "$ENV_FILE"
  echo "✓ Wrote $ENV_FILE (own bearer and Postgres password; prod .env untouched)"
}

client() {
  BASE_URL="http://$(env_value TAILNET_IP):$PORT" \
    IOS_BEARER_TOKEN="$(env_value IOS_BEARER_TOKEN)" \
    python3 e2e/e2e_client.py "$@"
}

cmd_up() {
  [ -f "$ENV_FILE" ] || write_env
  compose up -d --build --wait webapp
  echo "✓ vd-e2e up on http://<TAILNET_IP>:$PORT"
}

cmd_check() {
  require_env
  client health
}

cmd_session() {
  require_env
  client session "$@"
}

cmd_reset() {
  require_env
  compose stop webapp upstreams
  compose up -d --wait postgres qdrant

  # Drop and recreate from the same files postgres runs on first init.
  compose exec -T -e PGOPTIONS='-c client_min_messages=warning' postgres sh -c '
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
      -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\" WITH (FORCE)" \
      -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\"" &&
    psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      -f /docker-entrypoint-initdb.d/01-schema.sql \
      -f /docker-entrypoint-initdb.d/02-seed.sql'

  # Qdrant collections and stored bundles hold session state too; the webapp
  # recreates its collections on start.
  compose run --rm --no-deps -T --entrypoint python webapp - <<'PY'
import httpx

base = "http://qdrant:6333"
for c in httpx.get(base + "/collections").json()["result"]["collections"]:
    httpx.delete(f"{base}/collections/{c['name']}").raise_for_status()
PY
  compose run --rm --no-deps -T --entrypoint sh webapp -c 'rm -rf /data/sessions'

  compose up -d --wait upstreams webapp
  echo "✓ vd-e2e reset to the fixture cast"
}

cmd_down() {
  require_env
  compose down -v --remove-orphans
  echo "✓ vd-e2e removed (containers, network, volumes)"
}

case "${1:-}" in
  up) cmd_up ;;
  check) cmd_check ;;
  session) shift; cmd_session "$@" ;;
  reset) cmd_reset ;;
  down) cmd_down ;;
  *) echo "usage: e2e_stack.sh up|check|session|reset|down" >&2; exit 2 ;;
esac
