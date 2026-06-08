#!/usr/bin/env bash
# =============================================================================
# import-db.sh — Restore Yellow Bin SQL dumps into local self-hosted Supabase
# =============================================================================
# Run this from WSL2 inside ~/projects/supabase-project/ or anywhere you like.
# The script auto-detects the Postgres container and handles auth conflicts.
#
# Usage:
#   chmod +x import-db.sh
#   ./import-db.sh
#
# Requirements:
#   - Docker Desktop running
#   - Supabase stack healthy  (docker compose ps — all services Up)
#   - Dump files present in ~/projects/supabase-project/
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

echo -e "\n${BOLD}=== Yellow Bin — Local Supabase DB Import ===${RESET}\n"

# ── Config ────────────────────────────────────────────────────────────────────
DUMP_DIR="${HOME}/projects/supabase-project"
SCHEMA_FILE="${DUMP_DIR}/schema.sql"
DATA_FILE="${DUMP_DIR}/data.sql"
AUTH_FILE="${DUMP_DIR}/auth_users.sql"
DB_NAME="postgres"
DB_USER="postgres"

# ── Preflight checks ──────────────────────────────────────────────────────────
info "Checking dump files…"
for f in "$SCHEMA_FILE" "$DATA_FILE" "$AUTH_FILE"; do
  [[ -f "$f" ]] && success "Found: $f" || die "Missing dump file: $f"
done

info "Detecting Supabase Postgres container…"
# The official Supabase docker-compose names it 'supabase-db'; older forks use
# 'supabase_db'. We search for whichever is running.
DB_CONTAINER=$(docker ps --format '{{.Names}}' \
  | grep -E '^supabase[-_]db$' | head -1 || true)

if [[ -z "$DB_CONTAINER" ]]; then
  # Fall back: any running container whose image contains 'postgres'
  DB_CONTAINER=$(docker ps --format '{{.Names}}\t{{.Image}}' \
    | grep -i 'postgres' | awk '{print $1}' | head -1 || true)
fi

[[ -z "$DB_CONTAINER" ]] && die \
  "Could not find a running Postgres container. Is 'docker compose up -d' done?"

success "Using container: ${BOLD}${DB_CONTAINER}${RESET}"

# Quick connectivity test
info "Testing psql connectivity inside container…"
docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" \
  > /dev/null 2>&1 \
  || die "psql inside container failed. Check the container is healthy."
success "psql OK"

# ── SQL sanitiser ─────────────────────────────────────────────────────────────
# Strips lines from pg_dump output that cause errors when the dump was made
# against a newer Postgres than what's running locally.
#
# Rule 1 — bare psql meta-commands (\restrict, \echo, \connect, \set …)
#   Any line whose first non-space char is \ followed by a letter.
#   We KEEP \. (COPY terminator — starts with \. not \<letter>).
#
# Rule 2 — PG17-only GUC parameters not recognised by PG15
#   transaction_timeout  → introduced in PG17; default is 0 (no limit) anyway
#   (add more here if future dumps add new GUCs your local PG doesn't know)
sanitize_sql() {
  sed \
    -e '/^[[:space:]]*\\[a-zA-Z]/d' \
    -e '/^[[:space:]]*SET transaction_timeout[[:space:]]*=/d' \
    -e 's/^\([[:space:]]*CREATE SCHEMA[[:space:]]*\)\(public\b\)/\1IF NOT EXISTS \2/' \
    -e 's/^\([[:space:]]*CREATE \)\(FUNCTION\b\)/\1OR REPLACE \2/' \
    -e 's/^\([[:space:]]*CREATE \)\(PROCEDURE\b\)/\1OR REPLACE \2/' \
    -e 's/^\([[:space:]]*CREATE \)\(VIEW\b\)/\1OR REPLACE \2/'
  # Note: CREATE TYPE, TABLE, TRIGGER cannot use OR REPLACE in PG15 —
  # those are handled upstream by DROP SCHEMA public CASCADE.
}

# ── Helper: run SQL file inside container ─────────────────────────────────────
run_sql_file() {
  local label="$1"
  local file="$2"
  local extra_flags="${3:-}"          # optional extra psql flags
  local db="${4:-$DB_NAME}"

  local lines
  lines=$(wc -l < "$file")
  local stripped
  stripped=$(sanitize_sql < "$file" | wc -l)
  local removed=$(( lines - stripped ))

  info "Importing ${label} (${lines} lines; stripping ${removed} psql meta-commands)…"

  # Pipe through sanitiser before handing to psql.
  # shellcheck disable=SC2086
  sanitize_sql < "$file" \
    | docker exec -i $extra_flags "$DB_CONTAINER" \
        psql -U "$DB_USER" -d "$db" -v ON_ERROR_STOP=1 \
    && success "${label} imported successfully" \
    || die "${label} import failed — check output above"
}

# ── Step 1: schema.sql ────────────────────────────────────────────────────────
echo -e "\n${BOLD}[1/3] Importing public schema structure${RESET}"
info "Resetting public schema to a clean slate (idempotent — safe to re-run)…"
# Supabase Docker init always pre-creates the public schema, and our dump also
# contains CREATE SCHEMA public, so we must drop first.
# auth/storage/realtime schemas are untouched — they live outside public.
docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" <<'RESET_SQL'
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO postgres;
GRANT ALL ON SCHEMA public TO public;
COMMENT ON SCHEMA public IS 'standard public schema';
RESET_SQL
success "public schema reset"

info "This creates tables, types, indexes, RLS policies, etc."
run_sql_file "schema.sql" "$SCHEMA_FILE"

# ── Step 2: auth_users.sql (must precede data.sql) ───────────────────────────
# public.profiles has a FK → auth.users(id).  auth rows must exist first or
# data.sql will immediately violate "profiles_id_fkey".
echo -e "\n${BOLD}[2/3] Importing auth.users + auth.identities${RESET}"
info "auth rows must exist before public.profiles rows reference them."

if grep -q "^COPY " "$AUTH_FILE"; then
  warn "auth_users.sql uses COPY syntax — running with ON_ERROR_STOP=off."
  warn "Duplicate-key errors below are expected if Studio already has test users."
  # Prepend replica role so auth FK chains inside auth schema don't block COPY
  { echo "SET session_replication_role = replica;";
    sanitize_sql < "$AUTH_FILE";
    echo "SET session_replication_role = DEFAULT;"; } \
    | docker exec -i "$DB_CONTAINER" \
        psql -U "$DB_USER" -d "$DB_NAME"
  echo -e "${YELLOW}[WARN]${RESET}  auth import finished (any duplicate-key lines above are harmless)"
else
  info "auth_users.sql uses INSERT syntax — converting to ON CONFLICT DO NOTHING"
  { echo "SET session_replication_role = replica;";
    sanitize_sql < "$AUTH_FILE" \
      | sed 's/^\(INSERT INTO .*\);$/\1 ON CONFLICT DO NOTHING;/';
    echo "SET session_replication_role = DEFAULT;"; } \
    | docker exec -i "$DB_CONTAINER" \
        psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
    && success "auth_users.sql imported (conflicts silently skipped)" \
    || die "auth_users.sql import failed — check output above"
fi

# ── Step 3: data.sql ─────────────────────────────────────────────────────────
echo -e "\n${BOLD}[3/3] Importing public schema data${RESET}"
info "Restoring rows for profiles, contributions, events, gallery, content_posts, partnerships."
info "Running with session_replication_role=replica to bypass cross-schema FK ordering."
# session_replication_role=replica disables FK constraint checks and per-row
# triggers for the duration of this session — safe for a bulk restore because
# we already know the data is referentially consistent (it came from production).
{ echo "SET session_replication_role = replica;";
  sanitize_sql < "$DATA_FILE";
  echo "SET session_replication_role = DEFAULT;"; } \
  | docker exec -i "$DB_CONTAINER" \
      psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 \
  && success "data.sql imported successfully" \
  || die "data.sql import failed — check output above"

# ── Verification queries ──────────────────────────────────────────────────────
echo -e "\n${BOLD}=== Verification ===${RESET}"

info "Row counts for the 6 public tables:"
docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -x <<'SQL'
SELECT 'profiles'       AS "table", COUNT(*) AS rows FROM public.profiles
UNION ALL
SELECT 'contributions',             COUNT(*)          FROM public.contributions
UNION ALL
SELECT 'events',                    COUNT(*)          FROM public.events
UNION ALL
SELECT 'gallery',                   COUNT(*)          FROM public.gallery
UNION ALL
SELECT 'content_posts',             COUNT(*)          FROM public.content_posts
UNION ALL
SELECT 'partnerships',              COUNT(*)          FROM public.partnerships;
SQL

info "auth.users row count:"
docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" \
  -c "SELECT COUNT(*) AS auth_users FROM auth.users;"

info "auth.identities row count:"
docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" \
  -c "SELECT COUNT(*) AS auth_identities FROM auth.identities;"

echo -e "\n${GREEN}${BOLD}All done!${RESET}"
echo -e "Open Studio at ${BOLD}http://localhost:8000${RESET} → Table Editor to visually confirm."
echo -e "Default Studio creds are in ${BOLD}~/projects/supabase-project/.env${RESET}"
echo -e "  (DASHBOARD_USERNAME / DASHBOARD_PASSWORD)\n"
