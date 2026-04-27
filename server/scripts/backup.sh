#!/usr/bin/env bash
# Voice Diary server backup.
#
# Bundles the things that are not reproducible from a fresh clone:
#   - data/sessions/         — iOS session bundles + transcripts
#   - data/msal_cache.bin    — MSAL refresh-token cache (re-bootstrap is
#                              possible but disruptive)
#   - Postgres dump          — diary_processor schema + rows
#   - Qdrant snapshot        — contextual learning vectors
#
# Usage:
#     bash scripts/backup.sh [/path/to/output-dir]
#
# Environment:
#     BACKUP_DIR   default: ./backups   (overridden by the positional arg)
#     COMPOSE_CMD  default: docker compose
#
# Run from the repository's `server/` directory.

set -euo pipefail

BACKUP_DIR="${1:-${BACKUP_DIR:-./backups}}"
COMPOSE_CMD="${COMPOSE_CMD:-docker compose}"
TIMESTAMP="$(date +%Y-%m-%dT%H-%M-%S)"
WORKDIR="$(mktemp -d -t voice-diary-backup.XXXXXX)"
ARCHIVE="${BACKUP_DIR%/}/voice-diary-${TIMESTAMP}.tar.gz"

trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$BACKUP_DIR"

echo "→ Backup target: $ARCHIVE"
echo "→ Staging in:    $WORKDIR"

# 1. data/ tree (sessions + msal cache)
if [ -d "./data" ]; then
  cp -a ./data "$WORKDIR/data"
  echo "✓ Copied data/ ($(du -sh ./data 2>/dev/null | cut -f1 || echo unknown))"
else
  echo "! Skipping data/ — directory not found"
fi

# 2. Postgres dump (via the running webapp's pg sidecar)
if $COMPOSE_CMD ps postgres >/dev/null 2>&1; then
  echo "→ Dumping Postgres..."
  $COMPOSE_CMD exec -T postgres pg_dump -U diary -d diary_processor \
      --no-owner --clean --if-exists \
      > "$WORKDIR/postgres.sql"
  echo "✓ postgres.sql ($(du -sh "$WORKDIR/postgres.sql" | cut -f1))"
else
  echo "! Skipping Postgres — sidecar not running. Start with 'docker compose up -d postgres'."
fi

# 3. Qdrant snapshot via its HTTP API. This produces a *.snapshot file
# inside the container which we then copy out via docker cp.
if $COMPOSE_CMD ps qdrant >/dev/null 2>&1; then
  echo "→ Triggering Qdrant snapshot..."
  QDRANT_CONT="$($COMPOSE_CMD ps -q qdrant)"
  if [ -n "$QDRANT_CONT" ]; then
    # List collections, snapshot each.
    COLLECTIONS=$($COMPOSE_CMD exec -T qdrant \
                  sh -c 'wget -qO- http://localhost:6333/collections' \
                  | python3 -c 'import json,sys;print("\n".join(c["name"] for c in json.load(sys.stdin)["result"]["collections"]))' \
                  || true)
    mkdir -p "$WORKDIR/qdrant_snapshots"
    if [ -z "$COLLECTIONS" ]; then
      echo "! Qdrant has no collections to snapshot."
    else
      while IFS= read -r col; do
        [ -z "$col" ] && continue
        echo "  · snapshot collection $col"
        $COMPOSE_CMD exec -T qdrant \
          sh -c "wget -q --post-data='' -O- http://localhost:6333/collections/$col/snapshots" >/dev/null
      done <<< "$COLLECTIONS"
      docker cp "${QDRANT_CONT}:/qdrant/storage/" "$WORKDIR/qdrant_snapshots/storage"
      echo "✓ Qdrant snapshot copied"
    fi
  fi
else
  echo "! Skipping Qdrant — sidecar not running."
fi

# 4. Tar the staging directory.
tar -C "$WORKDIR" -czf "$ARCHIVE" .
echo
echo "✓ Wrote $(du -sh "$ARCHIVE" | cut -f1) to $ARCHIVE"
echo "  Contents:"
tar -tzf "$ARCHIVE" | head -20 | sed 's/^/    /'
