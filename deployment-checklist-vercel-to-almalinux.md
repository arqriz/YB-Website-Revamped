# Deployment Checklist: Vercel + GitHub → AlmaLinux + Nginx

**Migration:** Static HTML site from Vercel (auto-deploy from GitHub) to a dedicated AlmaLinux server with Nginx, Certbot SSL, and GitHub Actions CI/CD.  
**DNS:** Google Cloud DNS  
**Date:** ___________  
**Performed by:** ___________

---

## Phase 1 — Pre-Deployment Preparation
*Everything here can be done before you ever touch the server. Complete this phase fully before provisioning.*

- [ ] **Audit the repository structure**  
  Confirm which branch Vercel deploys from (usually `main`). All static files to be served should be under a known root (e.g., `./` or `./dist`). Note the exact path — you'll need it for Nginx `root` and the GitHub Actions deploy script.

- [ ] **Document current Vercel environment variables or headers**  
  Check Vercel project settings → Environment Variables and Headers/Redirects. Recreate any redirects (e.g., `www` → apex, HTTP → HTTPS) in Nginx config later. Nothing should be silently lost in the move.

- [ ] **Record current DNS TTL values in Google Cloud DNS**  
  Open Cloud DNS → your zone → note the TTL on the `A` / `CNAME` records pointing to Vercel. Lower them to **300 seconds (5 min)** now — changes propagate in TTL cycles, so doing this early compresses your cutover window.

- [ ] **Verify domain ownership and SSL baseline**  
  Run `curl -I https://yourdomain.com` and note the current cert issuer (Vercel uses Let's Encrypt). After migration Certbot will issue a fresh cert — just confirming the domain resolves cleanly now.

- [ ] **Generate an SSH key pair for GitHub Actions**  
  On your local machine:
  ```bash
  ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/github_deploy
  ```
  Keep `github_deploy` (private) and `github_deploy.pub` (public) ready. Do **not** commit either to the repo.

- [ ] **Prepare GitHub repository secrets**  
  In GitHub → repo → Settings → Secrets and variables → Actions, create:
  - `DEPLOY_HOST` — server IP or hostname
  - `DEPLOY_USER` — the deploy user you'll create on the server (e.g., `deployer`)
  - `DEPLOY_SSH_KEY` — contents of `~/.ssh/github_deploy` (private key)
  - `DEPLOY_PORT` — SSH port (default 22, or custom if you harden it)

- [ ] **Draft the GitHub Actions workflow file** (don't commit yet — do it after server is ready)  
  See Phase 5 for the full workflow. Having it drafted now means you can commit it in one step once the server accepts SSH connections.

- [ ] **Snapshot or export current Vercel project settings**  
  Screenshot or export: domain configuration, build settings, and any analytics. Acts as a reference if you need to roll back to Vercel.

---

## Phase 2 — Server Initial Setup & Hardening

*Run all commands as root initially, then switch to a sudo user.*

### 2a — First Login & System Baseline

- [ ] **Log in as root and update the system**
  ```bash
  dnf update -y && dnf upgrade -y
  ```
  Ensures you're not installing Nginx on top of unpatched packages.

- [ ] **Set the hostname**
  ```bash
  hostnamectl set-hostname yourhostname.yourdomain.com
  ```
  Makes logs and shell prompts identifiable, especially important if you run multiple servers.

- [ ] **Set timezone**
  ```bash
  timedatectl set-timezone Asia/Kuala_Lumpur   # adjust to your region
  ```
  Consistent timestamps in logs and cron jobs.

- [ ] **Create a non-root sudo user**
  ```bash
  useradd -m -G wheel adminuser
  passwd adminuser
  ```
  You should never operate day-to-day as root.

- [ ] **Create a dedicated deploy user (no sudo, restricted shell)**
  ```bash
  useradd -m -s /bin/bash deployer
  ```
  GitHub Actions will SSH in as this user. It only needs write access to the web root — not sudo. Least-privilege principle.

### 2b — SSH Hardening

- [ ] **Copy your personal SSH public key to the admin user**
  ```bash
  ssh-copy-id -i ~/.ssh/your_key.pub adminuser@SERVER_IP
  ```

- [ ] **Copy the GitHub Actions deploy public key to the deployer user**
  ```bash
  su - deployer
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  echo "PASTE_github_deploy.pub_CONTENTS" >> ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
  ```

- [ ] **Harden `/etc/ssh/sshd_config`**  
  Edit and confirm/set:
  ```
  PermitRootLogin no
  PasswordAuthentication no
  PubkeyAuthentication yes
  Port 22            # optionally change to a non-standard port
  AllowUsers adminuser deployer
  ```
  Disabling password auth eliminates brute-force risk entirely.

- [ ] **Restart SSH and verify you can still log in before closing your root session**
  ```bash
  systemctl restart sshd
  # In a NEW terminal: ssh adminuser@SERVER_IP
  ```
  Do not close your existing session until the new one works — locked-out recovery is painful.

### 2c — Firewall

- [ ] **Install and enable firewalld**
  ```bash
  dnf install -y firewalld
  systemctl enable --now firewalld
  ```

- [ ] **Open only required ports**
  ```bash
  firewall-cmd --permanent --add-service=ssh
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  firewall-cmd --reload
  ```
  All other ports stay closed by default. If you changed SSH port, use `--add-port=YOURPORT/tcp` instead of `--add-service=ssh`.

- [ ] **Verify open ports**
  ```bash
  firewall-cmd --list-all
  ```

### 2d — Fail2ban (optional but recommended)

- [ ] **Install and enable Fail2ban**
  ```bash
  dnf install -y epel-release && dnf install -y fail2ban
  systemctl enable --now fail2ban
  ```
  Automatically bans IPs with repeated failed SSH attempts.

---

## Phase 3 — Nginx Install & Static Site Configuration

### 3a — Install Nginx

- [ ] **Install Nginx**
  ```bash
  dnf install -y nginx
  systemctl enable --now nginx
  ```

- [ ] **Verify Nginx is serving the default page**  
  From your local browser: `http://SERVER_IP` — you should see the AlmaLinux Nginx welcome page. If not, check firewall and `systemctl status nginx`.

### 3b — Web Root & Permissions

- [ ] **Create the web root directory**
  ```bash
  mkdir -p /var/www/yourdomain.com
  chown -R deployer:deployer /var/www/yourdomain.com
  chmod -R 755 /var/www/yourdomain.com
  ```
  Nginx (running as `nginx` user) needs read access; `deployer` needs write access for deployments.

- [ ] **Add the nginx user to the deployer group (so Nginx can read deployer-owned files)**
  ```bash
  usermod -aG deployer nginx
  ```

### 3c — Nginx Server Block

- [ ] **Create a site config at `/etc/nginx/conf.d/yourdomain.com.conf`**
  ```nginx
  server {
      listen 80;
      listen [::]:80;
      server_name yourdomain.com www.yourdomain.com;

      root /var/www/yourdomain.com;
      index index.html;

      # Clean URLs — try file, then directory, then 404
      location / {
          try_files $uri $uri/ $uri.html =404;
      }

      # Security headers
      add_header X-Frame-Options "SAMEORIGIN" always;
      add_header X-Content-Type-Options "nosniff" always;
      add_header Referrer-Policy "strict-origin-when-cross-origin" always;

      # Cache static assets aggressively
      location ~* \.(css|js|jpg|jpeg|png|gif|svg|ico|woff2|woff)$ {
          expires 1y;
          add_header Cache-Control "public, immutable";
      }

      # Gzip
      gzip on;
      gzip_types text/plain text/css application/javascript image/svg+xml;
  }
  ```

- [ ] **Test and reload Nginx config**
  ```bash
  nginx -t && systemctl reload nginx
  ```
  Always test before reload — a config error will drop the site.

### 3d — Initial File Transfer

- [ ] **Do a one-time rsync from your local machine to confirm the pipeline works**
  ```bash
  rsync -avz --delete ./  deployer@SERVER_IP:/var/www/yourdomain.com/
  ```
  The `--delete` flag mirrors the source exactly, removing stale files on the server.

- [ ] **Verify the site loads over HTTP at `http://SERVER_IP`**  
  Check that `index.html` renders, images load, and internal links work.

---

## Phase 4 — SSL with Certbot

*Do this while DNS still points to Vercel — you'll use the `--standalone` or `--webroot` method against the server IP, or wait until DNS cutover and use the standard method. The approach below uses webroot, which works alongside running Nginx.*

- [ ] **Install Certbot and the Nginx plugin**
  ```bash
  dnf install -y certbot python3-certbot-nginx
  ```

- [ ] **Obtain the certificate**  
  *(Run this after DNS points to this server — see Phase 6)*
  ```bash
  certbot --nginx -d yourdomain.com -d www.yourdomain.com \
    --email your@email.com --agree-tos --non-interactive
  ```
  Certbot will automatically update your Nginx config with SSL directives and set up an HTTP→HTTPS redirect.

- [ ] **Verify auto-renewal is working**
  ```bash
  certbot renew --dry-run
  ```
  Certbot installs a systemd timer on AlmaLinux — confirm it's active:
  ```bash
  systemctl status certbot-renew.timer
  ```

- [ ] **Confirm HTTPS loads correctly after cert issuance**  
  Check `https://yourdomain.com` and `https://www.yourdomain.com` in a browser. Green padlock, no mixed-content warnings.

---

## Phase 5 — GitHub Actions Auto-Deploy Pipeline

- [ ] **Create `.github/workflows/deploy.yml` in your repository**
  ```yaml
  name: Deploy to AlmaLinux

  on:
    push:
      branches:
        - main          # adjust if your deploy branch differs

  jobs:
    deploy:
      runs-on: ubuntu-latest

      steps:
        - name: Checkout repository
          uses: actions/checkout@v4

        - name: Deploy via rsync over SSH
          uses: burnett01/rsync-deployments@7.0.1
          with:
            switches: -avz --delete
            path: ./                          # adjust if site root is a subdirectory
            remote_path: /var/www/yourdomain.com/
            remote_host: ${{ secrets.DEPLOY_HOST }}
            remote_port: ${{ secrets.DEPLOY_PORT }}
            remote_user: ${{ secrets.DEPLOY_USER }}
            remote_key: ${{ secrets.DEPLOY_SSH_KEY }}

        - name: Reload Nginx
          uses: appleboy/ssh-action@v1.0.3
          with:
            host: ${{ secrets.DEPLOY_HOST }}
            port: ${{ secrets.DEPLOY_PORT }}
            username: ${{ secrets.DEPLOY_USER }}
            key: ${{ secrets.DEPLOY_SSH_KEY }}
            script: |
              sudo nginx -t && sudo systemctl reload nginx
  ```

- [ ] **Grant the deployer user passwordless sudo for nginx reload only**  
  Edit sudoers via `visudo`:
  ```
  deployer ALL=(ALL) NOPASSWD: /usr/bin/nginx -t, /usr/bin/systemctl reload nginx
  ```
  Least-privilege: Actions can reload Nginx but cannot escalate further.

- [ ] **Commit and push the workflow file — verify the Action runs green**  
  Check GitHub → Actions tab. A failed rsync here means an SSH key or permissions issue — debug before DNS cutover.

- [ ] **Make a test content change, push to main, and confirm it appears on the server**
  ```bash
  ssh deployer@SERVER_IP "ls -la /var/www/yourdomain.com/"
  ```

---

## Phase 6 — DNS Cutover (Google Cloud DNS)

*This is the point of no return. Do it during low-traffic hours.*

### Pre-cutover checks
- [ ] The site loads correctly over HTTPS on the new server (verified by direct IP or hosts file override)
- [ ] GitHub Actions pipeline has deployed at least once successfully
- [ ] Certbot certificate is issued and valid
- [ ] TTL was already lowered to 300s (from Phase 1)

### Cutover steps

- [ ] **In Google Cloud DNS, update the `A` record(s) for the apex domain**
  - Old value: Vercel's IP(s) (e.g., `76.76.21.21`)
  - New value: your AlmaLinux server IP
  - TTL: 300 (keep low during the transition)

- [ ] **Update the `CNAME` or `A` record for `www`**  
  Point `www` to your server IP (or a CNAME to the apex if your DNS supports ALIAS/ANAME records). Remove any Vercel-specific CNAME (`cname.vercel-dns.com`).

- [ ] **Verify propagation from multiple locations**
  ```bash
  dig +short yourdomain.com @8.8.8.8
  dig +short www.yourdomain.com @1.1.1.1
  ```
  Both should return your server IP within 5 minutes given the 300s TTL.

- [ ] **Run Certbot now (if you deferred it from Phase 4)**
  ```bash
  certbot --nginx -d yourdomain.com -d www.yourdomain.com \
    --email your@email.com --agree-tos --non-interactive
  ```

- [ ] **Once stable, raise TTL back to 3600 or higher**  
  Low TTL means more DNS queries — raise it once you've confirmed everything is working.

- [ ] **Disable or pause Vercel auto-deploys** (don't delete the project yet — keep it as rollback)  
  Vercel → Project Settings → Git → disable automatic deployments.

---

## Phase 7 — Post-Deployment Verification

- [ ] **Full site walkthrough in browser**  
  Click through every page. Check navigation, images, fonts (especially if fonts are self-hosted), forms, and any embedded iframes.

- [ ] **Check HTTP → HTTPS redirect**
  ```bash
  curl -I http://yourdomain.com
  # Expect: 301 Location: https://yourdomain.com
  ```

- [ ] **Check www → apex redirect (or vice versa, per your preference)**
  ```bash
  curl -I https://www.yourdomain.com
  ```

- [ ] **Verify SSL certificate details**
  ```bash
  echo | openssl s_client -connect yourdomain.com:443 2>/dev/null | openssl x509 -noout -dates -issuer
  ```
  Confirm issuer is Let's Encrypt and expiry is ~90 days out.

- [ ] **Run a security headers check**  
  Visit `https://securityheaders.com/?q=yourdomain.com` — aim for an A or B grade.

- [ ] **Run an SSL Labs check**  
  Visit `https://ssllabs.com/ssltest/analyze.html?d=yourdomain.com` — aim for A.

- [ ] **Check Nginx error log is clean**
  ```bash
  sudo tail -50 /var/log/nginx/error.log
  ```

- [ ] **Confirm GitHub Actions auto-deploy still works post-DNS cutover**  
  Push a trivial change (e.g., HTML comment) to `main` and verify it appears live within a minute.

- [ ] **Check server resource baseline**
  ```bash
  top        # CPU/memory
  df -h      # disk usage
  ```

---

## Phase 8 — Rollback Plan

*If something goes critically wrong after DNS cutover, this is your escape hatch.*

### Triggers for rollback
- Site is unreachable or returning 5xx errors for more than 5 minutes
- SSL cert failed to issue and HTTPS is broken
- GitHub Actions pipeline is broken and you cannot deploy a fix

### Rollback steps

- [ ] **Re-enable Vercel auto-deploys**  
  Vercel → Project Settings → Git → re-enable automatic deployments. Vercel will redeploy from the current `main` branch immediately.

- [ ] **Revert DNS in Google Cloud DNS**  
  Change the `A` record back to Vercel's IP(s). Because TTL is still at 300s (you haven't raised it yet), propagation takes ~5 minutes.

- [ ] **Verify the site is back on Vercel**
  ```bash
  curl -I https://yourdomain.com
  # Check Server header — Vercel responses include `x-vercel-id`
  ```

- [ ] **Document what failed**  
  Before the next attempt, write down exactly what went wrong and what needs to be fixed on the AlmaLinux server.

- [ ] **Do not delete the AlmaLinux server** — it's still running and you can fix it without time pressure, then attempt cutover again.

---

## Quick Reference: Key File Paths

| Item | Path |
|---|---|
| Nginx site config | `/etc/nginx/conf.d/yourdomain.com.conf` |
| Web root | `/var/www/yourdomain.com/` |
| Nginx error log | `/var/log/nginx/error.log` |
| Nginx access log | `/var/log/nginx/access.log` |
| Certbot certs | `/etc/letsencrypt/live/yourdomain.com/` |
| Sudoers file | `/etc/sudoers.d/deployer` |
| GitHub Actions workflow | `.github/workflows/deploy.yml` |

---

*Checklist complete. Keep this document after migration — it doubles as a runbook for future server changes.*
