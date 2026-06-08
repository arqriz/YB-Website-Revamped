# DB Import — Troubleshooting & Manual Steps

Quick reference for every failure mode you're likely to hit during Step 1.

---

## Running the Script

```bash
# In WSL2 — the Windows workspace is mounted at /mnt/c/
cp "/mnt/c/Users/canon/Documents/YB Website/import-db.sh" ~/import-db.sh
chmod +x ~/import-db.sh
~/import-db.sh
```

Or run it from the Windows path directly:

```bash
chmod +x "/mnt/c/Users/canon/Documents/YB Website/import-db.sh"
"/mnt/c/Users/canon/Documents/YB Website/import-db.sh"
```

---

## Common Failures & Fixes

### 1. "Could not find a running Postgres container"

The auto-detect failed. Find the real name yourself:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | grep -i post
```

Then re-run with the name hardcoded at the top of the script (`DB_CONTAINER=`), or
export it before running:

```bash
DB_CONTAINER=supabase-db ~/import-db.sh
```

---

### 2. schema.sql fails with "role does not exist" or "extension missing"

Supabase's local stack ships with `pg_graphql`, `pg_stat_monitor`, etc. pre-installed.
If the dump references a role or extension that doesn't exist locally:

```bash
# List roles in the local container
docker exec supabase-db psql -U postgres -c '\du'

# List installed extensions
docker exec supabase-db psql -U postgres -c '\dx'

# If a role is missing (e.g. supabase_admin), create it:
docker exec supabase-db psql -U postgres \
  -c "CREATE ROLE supabase_admin WITH LOGIN SUPERUSER PASSWORD 'postgres';"
```

Then re-run `import-db.sh` from scratch (schema first).

---

### 3. schema.sql fails with "already exists"

Your local Supabase init already created some tables. Two options:

**Option A — Drop and recreate the public schema (clean slate):**

```bash
docker exec supabase-db psql -U postgres -d postgres <<'SQL'
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO postgres;
GRANT ALL ON SCHEMA public TO public;
SQL
# Then re-run the script
```

**Option B — Import with errors ignored (dirty but fast):**

```bash
docker exec -i supabase-db \
  psql -U postgres -d postgres \
  < ~/projects/supabase-project/schema.sql
# Duplicate-object errors are noise; check that the final table list looks right
```

---

### 4. data.sql fails with FK violation

Schema didn't fully apply, or tables are in the wrong order. Check which table
caused the error, then manually import just that table's data:

```bash
# Extract rows for one table and pipe them in
grep -A 9999 "COPY public.profiles" ~/projects/supabase-project/data.sql \
  | grep -B 9999 "^\\\." \
  | docker exec -i supabase-db psql -U postgres -d postgres
```

Or, temporarily disable FK checks for the session:

```bash
docker exec -i supabase-db psql -U postgres -d postgres <<SQL
SET session_replication_role = replica;   -- disables FK + trigger checks
\i /dev/stdin
SQL
# (doesn't work with stdin pipe — use the method below instead)

cat ~/projects/supabase-project/data.sql \
  | docker exec -i supabase-db \
      psql -U postgres -d postgres \
      -c "SET session_replication_role = replica;" -f -
```

Easiest workaround: prepend the setting to the dump:

```bash
(echo "SET session_replication_role = replica;"; cat data.sql) \
  | docker exec -i supabase-db psql -U postgres -d postgres
```

---

### 5. auth_users.sql — "duplicate key value violates unique constraint"

Expected if Studio already has a test user. The script handles this automatically.
If you want a clean auth state first:

```bash
docker exec supabase-db psql -U postgres -d postgres <<'SQL'
TRUNCATE auth.sessions, auth.refresh_tokens, auth.mfa_factors,
         auth.mfa_challenges, auth.identities, auth.users CASCADE;
SQL
# Then re-run the script — no conflicts possible
```

---

### 6. COPY fails inside Docker (permission denied / path not found)

This happens if psql tries to `COPY … FROM '/some/path'` instead of stdin.
The fix: tell pg_dump to use `--column-inserts` (INSERT format) when re-dumping.
For now, redirect via stdin (the script already does this with `< file`).

If your dump file has an absolute path in COPY:

```bash
# Replace the absolute COPY path with \copy (client-side) — not possible for docker exec.
# Instead, copy the dump file INTO the container first:
docker cp ~/projects/supabase-project/auth_users.sql supabase-db:/tmp/auth_users.sql
docker exec supabase-db psql -U postgres -d postgres \
  -f /tmp/auth_users.sql
```

---

## Manual Verification Queries

Run these any time in psql to check state:

```bash
docker exec -it supabase-db psql -U postgres -d postgres
```

```sql
-- All public tables with row counts
SELECT schemaname, relname, n_live_tup
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY relname;

-- Auth users
SELECT id, email, created_at FROM auth.users LIMIT 10;

-- Auth identities
SELECT id, user_id, provider FROM auth.identities LIMIT 10;

-- RLS enabled?
SELECT tablename, rowsecurity
FROM pg_tables
WHERE schemaname = 'public';

-- Storage buckets (created by Supabase init, not your SQL dumps)
SELECT id, name, public FROM storage.buckets;
```

---

## After a Successful Import

Move to **Step 2 — Migrate Storage Buckets**.

The three buckets (`events`, `gallery`, `content`) exist as rows in `storage.buckets`
but their actual files live in MinIO (the `storage` Docker container, backed by
`~/projects/supabase-project/volumes/storage/`). Step 2 will pull files from the
live Supabase Storage API and upload them to local MinIO.
