# Session Handoff Prompt
# Copy everything below this line and paste it into a new chat.
---

I'm an intern migrating the Yellow Bin website off Vercel + hosted Supabase onto a self-hosted stack. I've completed local proof-of-concept (Steps 1–2) and am now deploying to a GCP VPS for the real migration.

**Stack:** 15+ static HTML pages, Tailwind CDN, no React. Supabase JS SDK via CDN pointing at `https://pwcdqhcnmzylxvftousp.supabase.co`. Supabase handles Auth, 6 Postgres tables (profiles, contributions, events, gallery, content_posts, partnerships), 3 storage buckets (events, gallery, content), role-based admin via profiles.role.

---

## Environment

- WSL2 Ubuntu on Windows, Docker Desktop running
- Self-hosted Supabase stack at `~/projects/supabase-project/` — all 12 services healthy, Studio at `localhost:8000`
- Live Supabase is **PostgreSQL 17** (hosted). Local Docker stack is **PostgreSQL 15** (`supabase-db` container)
- Workspace folder synced between Windows and WSL2:
  - Windows: `C:\Users\canon\Documents\YB Website\`
  - WSL2 mount: `/mnt/c/Users/canon/Documents/YB Website/`
- **VPS:** Google Cloud Platform (GCP) — being set up now

## Key Scripts in Workspace (`C:\Users\canon\Documents\YB Website\`)

| File | Purpose |
|------|---------|
| `import-db.sh` | Imports schema + data SQL dumps into local/VPS Supabase. Copy to `~/import-db.sh` in WSL2/VPS before running. |
| `migrate-storage.py` | Copies storage buckets from live Supabase → local/VPS MinIO. Run with `python3 migrate-storage.py`. |
| `IMPORT-NOTES.md` | Manual fix reference for every known SQL import failure mode |
| `HANDOFF-PROMPT.md` | This file |

## SQL Dumps (in WSL2)

| File | Contents |
|------|----------|
| `~/projects/supabase-project/schema.sql` | public schema, structure only |
| `~/projects/supabase-project/data.sql` | public schema, data only |
| `~/projects/supabase-project/auth_users.sql` | auth.users + auth.identities, data only |

---

## Completed Steps

### ✅ Step 1 — SQL Import (local)
- Schema + data + auth successfully imported into local Supabase Docker
- Key fixes baked into `import-db.sh`: strips PG17-only GUCs, `CREATE OR REPLACE` for functions/views, `DROP SCHEMA public CASCADE` before import (requires `-i` flag on `docker exec` for heredoc to work)

### ✅ Step 2 — Storage Migration (local)
- All 3 buckets (events, gallery, content) created locally and files migrated via `migrate-storage.py`
- Storage RLS policies applied manually via psql:
  - `events`: "Public can view events" (SELECT) + "Authenticated users can upload to events" (INSERT)
  - `gallery`: "Public can view gallery" (SELECT) + "Authenticated users can upload to gallery" (INSERT)
  - `content`: no policies (matches live — bucket exists but has 0 policies)

---

## Current Step: Step 3 — Refactor HTML files to use `js/config.js`

### What needs to be done
All 15 HTML files currently have the Supabase URL and anon key **hardcoded** inline:
```js
const SUPABASE_URL = 'https://pwcdqhcnmzylxvftousp.supabase.co'
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...'
```

These need to be extracted into a single `js/config.js` file:
```js
// js/config.js
const SUPABASE_URL  = 'https://pwcdqhcnmzylxvftousp.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...';
```

Then each HTML file gets:
```html
<script src="/js/config.js"></script>
```
added **before** any other script that references `SUPABASE_URL` or `SUPABASE_ANON_KEY`, and the hardcoded inline declarations removed.

### HTML files to refactor (15 files in `C:\Users\canon\Documents\YB Website\`)
404.html, about.html, admin.html, blog.html, dashboard.html, faq.html, find-a-bin.html,
gallery.html, how-it-works.html, index.html, login.html, our-impact.html, partner.html,
signup.html, sitemap.html

### Live credentials (for reference — will be swapped per environment)
- `SUPABASE_URL`: `https://pwcdqhcnmzylxvftousp.supabase.co`
- `SUPABASE_ANON_KEY`: `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InB3Y2RxaGNubXp5bHh2ZnRvdXNwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUxMDYwNDcsImV4cCI6MjA5MDY4MjA0N30.Z2jR0GM5KZj7xfpxnxX37rDoG7XRUy82jseirJfQvxU`

### Local credentials (for testing after refactor)
- `SUPABASE_URL`: `http://localhost:8000`
- `SUPABASE_ANON_KEY`: get from `~/projects/supabase-project/.env` → `ANON_KEY`

---

## Remaining Roadmap

| Step | Task | Status |
|------|------|--------|
| 1 | Import schema + data into local Supabase | ✅ Done |
| 2 | Migrate storage buckets to local MinIO | ✅ Done |
| 3 | Refactor 15 HTML files → `js/config.js` | 🔄 Next |
| 4 | End-to-end local test (signup, login, admin panel, file uploads) | ⏳ Pending |
| 5 | Package for VPS: `docker-compose.prod.yml`, Nginx + Certbot, `DEPLOYMENT.md`, `BACKUP.md` | ⏳ Pending |

---

## Notes for VPS (GCP) Deployment
- Use Postgres image `supabase/postgres:17.4.1.038` in `docker-compose.prod.yml` to match live PG17 exactly — eliminates all the `sanitize_sql` PG15 workarounds
- At VPS cutover: put live site in maintenance mode → take fresh SQL dumps → run `import-db.sh` and `migrate-storage.py` on VPS → switch DNS
- `session_replication_role=replica` used during bulk import only — safe, constraints re-enable after session
- Storage RLS policies must be applied after import (they live in `storage` schema, not in the SQL dumps)
