#!/usr/bin/env python3
"""
migrate-storage.py — Copy storage buckets from live Supabase → local self-hosted Supabase
Run from WSL2:  python3 /mnt/c/Users/canon/Documents/YB\ Website/migrate-storage.py

Live  → https://pwcdqhcnmzylxvftousp.supabase.co  (anon key, public buckets)
Local → http://localhost:8000  (service role key from .env)
"""

import json
import os
import sys
import time
import tempfile
from pathlib import Path

try:
    import requests
except ImportError:
    print("[ERROR] 'requests' not installed. Run: pip3 install requests --break-system-packages")
    sys.exit(1)

# ── Config ────────────────────────────────────────────────────────────────────
LIVE_URL  = "https://pwcdqhcnmzylxvftousp.supabase.co"
LIVE_KEY  = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    ".eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InB3Y2RxaGNubXp5bHh2ZnRvdXNwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUxMDYwNDcsImV4cCI6MjA5MDY4MjA0N30"
    ".Z2jR0GM5KZj7xfpxnxX37rDoG7XRUy82jseirJfQvxU"
)
LOCAL_URL = "http://localhost:8000"
ENV_FILE  = Path.home() / "projects/supabase-project/.env"
BUCKETS   = ["events", "gallery", "content"]

# ── Colours ───────────────────────────────────────────────────────────────────
R = "\033[0;31m"; G = "\033[0;32m"; Y = "\033[1;33m"
C = "\033[0;36m"; B = "\033[1m";    X = "\033[0m"

def info(msg):    print(f"{C}[INFO]{X}  {msg}")
def ok(msg):      print(f"{G}[OK]{X}    {msg}")
def warn(msg):    print(f"{Y}[WARN]{X}  {msg}")
def die(msg):     print(f"{R}[ERROR]{X} {msg}", file=sys.stderr); sys.exit(1)

# ── Read local service role key from .env ─────────────────────────────────────
def load_local_key():
    if not ENV_FILE.exists():
        die(f".env not found at {ENV_FILE}")
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if line.startswith("SERVICE_ROLE_KEY="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    die("SERVICE_ROLE_KEY not found in .env")

# ── Supabase Storage helpers ───────────────────────────────────────────────────
def storage_headers(key):
    return {"Authorization": f"Bearer {key}", "apikey": key}

def list_objects(base_url, key, bucket, prefix=""):
    """List objects at 'prefix' level. Returns (files, folders)."""
    url = f"{base_url}/storage/v1/object/list/{bucket}"
    payload = {
        "limit": 1000,
        "offset": 0,
        "prefix": prefix,
        "sortBy": {"column": "name", "order": "asc"},
    }
    r = requests.post(url, json=payload, headers=storage_headers(key), timeout=30)
    if r.status_code == 400 and "not found" in r.text.lower():
        warn(f"Bucket '{bucket}' not found on source — skipping")
        return [], []
    if r.status_code != 200:
        die(f"list_objects failed ({r.status_code}): {r.text[:300]}")
    items = r.json()
    files   = [i for i in items if i.get("id") is not None]
    folders = [i for i in items if i.get("id") is None and i["name"] != ".emptyFolderPlaceholder"]
    return files, folders

def list_all_files(base_url, key, bucket, prefix=""):
    """Recursively list every file in a bucket. Returns list of full paths."""
    files, folders = list_objects(base_url, key, bucket, prefix)
    paths = []
    for f in files:
        full = f"{prefix}{f['name']}" if not prefix else f"{prefix}{f['name']}"
        paths.append(full)
    for folder in folders:
        folder_prefix = f"{prefix}{folder['name']}/"
        paths.extend(list_all_files(base_url, key, bucket, folder_prefix))
    return paths

def download_file(base_url, key, bucket, path, dest):
    """Download a single file. Tries authenticated endpoint; falls back to public."""
    url_auth   = f"{base_url}/storage/v1/object/{bucket}/{path}"
    url_public = f"{base_url}/storage/v1/object/public/{bucket}/{path}"
    r = requests.get(url_auth, headers=storage_headers(key), timeout=60, stream=True)
    if r.status_code in (400, 404):
        r = requests.get(url_public, timeout=60, stream=True)
    if r.status_code != 200:
        warn(f"  Could not download {path} ({r.status_code}) — skipping")
        return False
    dest.parent.mkdir(parents=True, exist_ok=True)
    with open(dest, "wb") as fh:
        for chunk in r.iter_content(chunk_size=65536):
            fh.write(chunk)
    return True

def create_bucket_local(local_url, key, bucket):
    """Create bucket locally (public). Idempotent — ignores already-exists."""
    url = f"{local_url}/storage/v1/bucket"
    payload = {"id": bucket, "name": bucket, "public": True}
    r = requests.post(url, json=payload, headers=storage_headers(key), timeout=15)
    if r.status_code in (200, 201):
        ok(f"  Bucket '{bucket}' created locally")
    elif "already exists" in r.text.lower() or r.status_code == 409:
        info(f"  Bucket '{bucket}' already exists locally — continuing")
    else:
        die(f"  Could not create bucket '{bucket}' ({r.status_code}): {r.text[:300]}")

def upload_file(local_url, key, bucket, path, src):
    """Upload a file to local Supabase storage, replacing if exists."""
    url = f"{local_url}/storage/v1/object/{bucket}/{path}"
    # Guess MIME type from extension
    import mimetypes
    mime, _ = mimetypes.guess_type(path)
    if not mime:
        mime = "application/octet-stream"
    headers = {**storage_headers(key), "Content-Type": mime, "x-upsert": "true"}
    with open(src, "rb") as fh:
        r = requests.post(url, data=fh, headers=headers, timeout=120)
    if r.status_code in (200, 201):
        return True
    warn(f"  Upload failed for {path} ({r.status_code}): {r.text[:200]}")
    return False

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    print(f"\n{B}=== Yellow Bin — Storage Migration (Live → Local) ==={X}\n")

    info("Loading local service role key from .env…")
    local_key = load_local_key()
    ok(f"Service role key loaded ({local_key[:20]}…)")

    # Sanity-check local Supabase is reachable
    info("Checking local Supabase storage is reachable…")
    try:
        r = requests.get(f"{LOCAL_URL}/storage/v1/bucket",
                         headers=storage_headers(local_key), timeout=10)
        if r.status_code not in (200, 201):
            die(f"Local storage returned {r.status_code}: {r.text[:200]}")
    except requests.exceptions.ConnectionError:
        die("Cannot reach http://localhost:8000 — is the Supabase stack running?")
    ok("Local storage reachable")

    total_ok = total_fail = 0

    with tempfile.TemporaryDirectory(prefix="yb-storage-") as tmpdir:
        tmp = Path(tmpdir)

        for bucket in BUCKETS:
            print(f"\n{B}── Bucket: {bucket} ──{X}")

            # 1. List all files from live
            info(f"Listing all files in live '{bucket}' bucket…")
            all_files = list_all_files(LIVE_URL, LIVE_KEY, bucket)
            if not all_files:
                warn(f"  No files found in '{bucket}' — bucket empty or not found, skipping")
                continue
            ok(f"  Found {len(all_files)} file(s)")

            # 2. Create bucket locally
            create_bucket_local(LOCAL_URL, local_key, bucket)

            # 3. Download → upload each file
            for i, fpath in enumerate(all_files, 1):
                dest = tmp / bucket / fpath
                print(f"  [{i}/{len(all_files)}] {fpath}", end=" … ", flush=True)

                # Download from live
                downloaded = download_file(LIVE_URL, LIVE_KEY, bucket, fpath, dest)
                if not downloaded:
                    total_fail += 1
                    continue

                # Upload to local
                uploaded = upload_file(LOCAL_URL, local_key, bucket, fpath, dest)
                if uploaded:
                    print(f"{G}✓{X}")
                    total_ok += 1
                else:
                    total_fail += 1

                # Small pause to avoid hammering live API
                time.sleep(0.05)

    print(f"\n{B}=== Migration complete ==={X}")
    print(f"  {G}Successful:{X} {total_ok} files")
    if total_fail:
        print(f"  {R}Failed:{X}     {total_fail} files")
    print(f"\nOpen Studio → Storage at {B}http://localhost:8000{X} to confirm.\n")

if __name__ == "__main__":
    main()
