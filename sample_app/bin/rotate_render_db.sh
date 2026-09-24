#!/usr/bin/env bash
# Rotates a Render free-tier Postgres instance before its 30-day expiry:
# dump -> delete old -> create new (same name) -> restore -> relink env var -> redeploy.
# Required tools: curl, jq, pg_dump, pg_restore, psql.
#
# Required env vars: RENDER_API_KEY, RENDER_OWNER_ID, RENDER_DB_NAME, RENDER_WEB_SERVICE_ID
# Optional: BACKUP_DIR (default ./backups)
#
# Free tier allows only one active instance at a time, so the old one is deleted
# before the new one exists - an unavoidable zero-database window.

set -euo pipefail

# GitHub Actions' log viewer renders ANSI color despite stdout not being a tty, so
# gate on GITHUB_ACTIONS too, not just -t 1.
if { [ -t 1 ] || [ -n "${GITHUB_ACTIONS:-}" ]; } && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; RESET=""
fi

log() { echo "${CYAN}[$(date +%H:%M:%S)]${RESET} $*"; }
warn() { log "${YELLOW}WARNING:${RESET} $*"; }
die() { log "${RED}${BOLD}FATAL:${RESET} $*"; exit 1; }
# Catches failures that don't go through die() (e.g. jq/psql crashing) so set -e
# doesn't exit silently.
trap 'log "${RED}${BOLD}FATAL:${RESET} unexpected failure at line $LINENO running: $BASH_COMMAND"' ERR

# Fail fast if a required binary is missing rather than dying mid-run.
for tool in curl jq pg_dump pg_restore psql; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found on PATH: $tool"
done

# "${VAR:?msg}" errors out with msg if VAR is unset/empty - cheap validation upfront.
: "${RENDER_API_KEY:?set RENDER_API_KEY}"
: "${RENDER_OWNER_ID:?set RENDER_OWNER_ID}"
: "${RENDER_DB_NAME:?set RENDER_DB_NAME}"
: "${RENDER_WEB_SERVICE_ID:?set RENDER_WEB_SERVICE_ID}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"

API="https://api.render.com/v1"
AUTH=(-H "Authorization: Bearer $RENDER_API_KEY" -H "Accept: application/json")

# Thin wrapper around every Render API call. Appends the HTTP status via curl -w,
# splits it back out, and warns on 4xx/5xx so failures surface here, not downstream.
api() {
  local method=$1 path=$2 response http_code body
  shift 2
  response=$(curl -sS -w $'\n%{http_code}' -X "$method" "$API$path" "${AUTH[@]}" "$@")
  http_code=$(tail -n1 <<< "$response")
  body=$(sed '$d' <<< "$response")
  if [ "$http_code" -ge 400 ]; then
    warn "$method $path -> HTTP $http_code: $body"
  fi
  echo "$body"
}

# Returns "tablename:count" per table, ordered by name - diffable before/after
# restore to catch missing tables or rows. xpath(query_to_xml(...)) is the standard
# Postgres trick for a dynamic per-table count without a client-side loop.
table_row_counts() {
  local conn=$1
  psql "$conn" -tAc "
    select tablename || ':' ||
      (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', schemaname, tablename), false, true, '')))[1]::text
    from pg_tables
    where schemaname = 'public'
    order by tablename;
  "
}

mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
DUMP_FILE="$BACKUP_DIR/${RENDER_DB_NAME}-${STAMP}.dump"
# Last known-good row counts, used to detect a broken leftover from a failed prior
# rotation. Needs actions/cache on $BACKUP_DIR in CI to persist between runs.
STATE_FILE="$BACKUP_DIR/last-good-row-counts.txt"

# --- Step 1: find the instance to rotate ---
log "looking up postgres instance named $RENDER_DB_NAME"
OLD_LOOKUP=$(api GET "/postgres?name=$RENDER_DB_NAME&ownerId=$RENDER_OWNER_ID")
OLD_MATCHES=$(jq 'length' <<< "$OLD_LOOKUP")
[ "$OLD_MATCHES" -ge 1 ] || die "no postgres instance found named $RENDER_DB_NAME"
# Refuse to guess which instance to delete if the name isn't unique.
[ "$OLD_MATCHES" -eq 1 ] || die "ambiguous: $OLD_MATCHES instances named $RENDER_DB_NAME - resolve manually, refusing to guess which one to delete"
OLD_ID=$(jq -r '.[0].postgres.id' <<< "$OLD_LOOKUP")
log "found $OLD_ID"

OLD_CONN=$(api GET "/postgres/$OLD_ID/connection-info" | jq -r '.externalConnectionString')
[ -n "$OLD_CONN" ] && [ "$OLD_CONN" != "null" ] || die "could not fetch connection info for $OLD_ID"
log "connection info for $OLD_ID retrieved"

# --- Step 2: dump and verify it before anything is deleted ---
log "dumping to $DUMP_FILE"
pg_dump "$OLD_CONN" -Fc -f "$DUMP_FILE"  # -Fc: custom format, required by pg_restore (not plain SQL)

# A near-empty dump usually means pg_dump failed silently - catch it before deleting the old instance.
DUMP_SIZE=$(stat -f%z "$DUMP_FILE" 2>/dev/null || stat -c%s "$DUMP_FILE")  # -f%z BSD/macOS, -c%s GNU/Linux
[ "$DUMP_SIZE" -gt 1024 ] || die "dump suspiciously small ($DUMP_SIZE bytes) - aborting before touching the live database"
log "dump written: $DUMP_SIZE bytes"

# Ground truth for the post-restore check, taken while the source DB still exists.
log "recording source row counts before touching the old instance"
SOURCE_ROW_COUNTS=$(table_row_counts "$OLD_CONN")
log "source row counts:"$'\n'"${SOURCE_ROW_COUNTS:-<no public tables found>}"

# If a previous run died mid-rotation, the "old" instance found above may actually be
# that failed run's half-finished replacement. Catch it before propagating broken data forward.
if [ -f "$STATE_FILE" ]; then
  log "checking current data against the last known-good snapshot ($STATE_FILE)"
  while IFS=: read -r table expected_count; do
    [ -z "$table" ] && continue
    actual_count=$(grep "^${table}:" <<< "$SOURCE_ROW_COUNTS" | cut -d: -f2)
    actual_count="${actual_count:-0}"
    if [ "$actual_count" -lt "$expected_count" ]; then
      die "table '$table' has fewer rows now ($actual_count) than the last known-good rotation ($expected_count) - this instance ($OLD_ID) looks like a broken leftover from an incomplete prior run, not a healthy prior generation. Refusing to dump/delete it. Recover manually: find the most recent *.dump file in $BACKUP_DIR and restore it by hand into a fresh instance."
    fi
  done < "$STATE_FILE"
  log "${GREEN}current data looks healthy${RESET} compared to last known-good snapshot"
else
  log "no prior known-good snapshot at $STATE_FILE - skipping regression check (first run, or the file was removed)"
fi

# --- Step 3: delete old, create new (free tier only allows one at a time) ---
log "deleting old instance $OLD_ID (frees the one-free-db slot)"
api DELETE "/postgres/$OLD_ID" >/dev/null

log "creating new free postgres named $RENDER_DB_NAME"
# Must set ipAllowList explicitly - the API defaults new instances to an EMPTY list,
# which blocks all external connections (unlike the dashboard's default). Without
# this, every dump/restore below fails with a misleading SSL error.
NEW_JSON=$(api POST "/postgres" -H "Content-Type: application/json" \
  -d "{\"name\":\"$RENDER_DB_NAME\",\"plan\":\"free\",\"ownerId\":\"$RENDER_OWNER_ID\",\"version\":\"16\",\"ipAllowList\":[{\"cidrBlock\":\"0.0.0.0/0\",\"description\":\"external access for dump/restore\"}]}")
NEW_ID=$(jq -r '.id // empty' <<< "$NEW_JSON")
[ -n "$NEW_ID" ] || die "create failed: $NEW_JSON (old instance is already gone - restore $DUMP_FILE into a manually created instance)"
log "created $NEW_ID, waiting for it to become available"

# --- Step 4: wait for the new instance, twice ---
# First wait: for Render's own status field to say the instance exists and is provisioned.
STATUS=""
WAITED=0
for i in $(seq 1 60); do
  STATUS=$(api GET "/postgres/$NEW_ID" | jq -r '.status')
  [ "$STATUS" = "available" ] && break
  log "waiting for $NEW_ID to be provisioned ($i/60)"
  sleep 10
  WAITED=$((WAITED + 10))
done
[ "$STATUS" = "available" ] || die "new instance $NEW_ID never became available (last status: $STATUS) - backup is at $DUMP_FILE"
log "$NEW_ID provisioned after ${WAITED}s"

NEW_CONN=$(api GET "/postgres/$NEW_ID/connection-info" | jq -r '.externalConnectionString')
[ -n "$NEW_CONN" ] && [ "$NEW_CONN" != "null" ] || die "could not fetch connection info for new instance $NEW_ID - backup is at $DUMP_FILE"

# "available" status isn't proof the instance accepts connections yet - test a real
# connection directly instead of trusting the status field.
READY=""
WAITED=0
for i in $(seq 1 30); do
  psql "$NEW_CONN" -tAc "select 1" >/dev/null 2>&1 && { READY=1; break; }
  log "waiting for $NEW_ID to accept connections ($i/30)"
  sleep 10
  WAITED=$((WAITED + 10))
done
[ -n "$READY" ] || die "instance $NEW_ID reports available but refuses connections after 5 minutes - backup is at $DUMP_FILE, investigate manually"
log "$NEW_ID accepting connections after ${WAITED}s"

# --- Step 5: restore and verify ---
log "restoring into new instance"
# pg_restore exits non-zero on any skipped statement, even harmless version-mismatch
# ones - not treated as fatal here, the row count check below is the real gate.
pg_restore -d "$NEW_CONN" --no-owner --no-privileges "$DUMP_FILE" \
  || warn "pg_restore reported errors (often a harmless version-mismatch SET) - verifying via row counts next"

log "comparing row counts against the pre-dump snapshot"
RESTORED_ROW_COUNTS=$(table_row_counts "$NEW_CONN")
log "restored row counts:"$'\n'"${RESTORED_ROW_COUNTS:-<no public tables found>}"
# The real integrity gate: table existence alone isn't enough, a table could restore empty.
if [ "$SOURCE_ROW_COUNTS" != "$RESTORED_ROW_COUNTS" ]; then
  die "row counts don't match after restore - new (mismatched) db is $NEW_ID, backup is $DUMP_FILE, service still points at the old (deleted) db. expected:"$'\n'"$SOURCE_ROW_COUNTS"$'\n'"got:"$'\n'"$RESTORED_ROW_COUNTS"
fi
log "${GREEN}row counts match exactly${RESET}"

# Written now, not after deploy - the database is legitimately good even if deploy fails below.
echo "$RESTORED_ROW_COUNTS" > "$STATE_FILE"

# --- Step 6: only now, with a verified-good database, touch the live app ---
log "pointing DATABASE_URL on $RENDER_WEB_SERVICE_ID at the new database"
api PUT "/services/$RENDER_WEB_SERVICE_ID/env-vars/DATABASE_URL" \
  -H "Content-Type: application/json" -d "{\"value\":\"$NEW_CONN\"}" >/dev/null

# Render does not auto-deploy on an env var change - the deploy must be triggered explicitly.
log "triggering redeploy"
DEPLOY_JSON=$(api POST "/services/$RENDER_WEB_SERVICE_ID/deploys" -H "Content-Type: application/json" -d '{}')
DEPLOY_ID=$(jq -r '.id // empty' <<< "$DEPLOY_JSON")
[ -n "$DEPLOY_ID" ] || die "env var was updated but triggering the deploy failed: $DEPLOY_JSON - trigger it manually from the dashboard"

SERVICE_URL=$(api GET "/services/$RENDER_WEB_SERVICE_ID" | jq -r '.serviceDetails.url // empty')

log "${GREEN}${BOLD}done.${RESET} new db id: $NEW_ID, deploy: $DEPLOY_ID, backup kept at $DUMP_FILE"
[ -n "$SERVICE_URL" ] && log "deployed to: $SERVICE_URL"
