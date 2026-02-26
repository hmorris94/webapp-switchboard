# VPS Setup Guide

Operational guide for deploying WebApp Switchboard to a public VPS. The `deploy/` directory contains everything needed.

## What's in `deploy/`

| File | Purpose |
|---|---|
| `config.template.sh` | Committed template — copy to `config.local.sh` and fill in |
| `config.local.sh` | Gitignored — real server values (you create this) |
| `setup.sh` | One-time server bootstrap (sources `config.local.sh`) |
| `deploy.sh` | Rolling update from your local machine (sources `config.local.sh`) |
| `switchboard.service` | Systemd unit template (placeholders filled by `setup.sh`) |
| `gunicorn.conf.py` | Gunicorn: Unix socket, 2 workers, application factory, 60s timeout |
| `nginx.conf` | Nginx: HTTP→HTTPS redirect, reverse proxy to Gunicorn socket |

## Architecture

```
Internet (HTTPS :443)
    ↓
nginx
    ↓ unix socket /run/switchboard/gunicorn.sock
Gunicorn (2 workers, preload_app)
    ↓ create_app()
WebApp Switchboard Flask app
    ↓ blueprints
/project-a/  /project-b/  ...
```

---

## 1. Create the VPS

Recommended baseline (DigitalOcean, Linode, Vultr, etc.):

- **OS**: Ubuntu 22.04 or 24.04 LTS
- **Size**: 1 vCPU / 1 GB RAM — adequate for personal traffic; `setup.sh` creates a 2 GB swap file to handle memory spikes
- **Auth**: SSH key only — disable password auth

Note the public IPv4 after creation.

## 2. DNS

At your DNS provider, create an `A` record pointing your domain to the VPS IP. Wait for propagation:

```bash
dig +short your-domain.com
# Should return your VPS IP
```

TLS provisioning (certbot) will fail if DNS isn't resolving first.

## 3. First login

```bash
ssh root@YOUR_VPS_IP
```

`setup.sh` creates the `switchboard` app user (a real login user with a home directory and SSH keys) — no manual user creation needed at this step.

## 4. Prepare local config

`deploy/config.local.sh` is gitignored and must be created on your **local machine**. `deploy.sh` sources it to get the SSH target, deploy root, and project list before connecting to the server.

```bash
cp deploy/config.template.sh deploy/config.local.sh
$EDITOR deploy/config.local.sh
```

Fill in all variables:

- `SWITCHBOARD_USER` — OS user that runs the service and owns all files; also the SSH login user (default: `switchboard`)
- `DEPLOY_ROOT` — where all repos live; defaults to `/home/$SWITCHBOARD_USER`
- `DOMAIN`, `CERTBOT_EMAIL` — your domain and Let's Encrypt contact email
- `PROJECTS` — array of `"directory_name|git_url"` entries; `directory_name` must match the `"directory"` field in `projects_local.py`

The server also needs its own copy of `config.local.sh` so that `setup.sh` can run — copy it over in step 5. `projects_local.py` is server-only and is also created in step 5.

## 5. Bootstrap the server

**On the server as root**, pre-create `DEPLOY_ROOT` and bootstrap-clone the switchboard repo. The path must match `DEPLOY_ROOT` from your config (default: `/home/switchboard`). Use the switchboard URL from the first entry of your `PROJECTS` array in `config.local.sh`:

```bash
mkdir -p /home/switchboard
git clone <your-switchboard-repo-url> /home/switchboard/webapp-switchboard
```

`mkdir` is required here: the `switchboard` user doesn't exist until `setup.sh` runs, so there is no home directory yet — git cannot clone into a path whose parent doesn't exist. `setup.sh` fixes ownership once the user is created.

**From your local machine**, copy `config.local.sh` to the server:

```bash
scp deploy/config.local.sh root@your-domain.com:/home/switchboard/webapp-switchboard/deploy/config.local.sh
```

**Back on the server as root**, create `projects_local.py`:

```bash
cd /home/switchboard/webapp-switchboard
cp projects_template.py projects_local.py
$EDITOR projects_local.py
```

Run the bootstrap script:

```bash
bash deploy/setup.sh
```

This installs:
1. 2 GB swap file (with `vm.swappiness=10`)
2. System packages (Python 3, nginx, certbot, git, ufw)
3. Chromium + ChromeDriver (for projects that use Selenium scraping)
4. `switchboard` login user with home directory and SSH authorized_keys
5. Passwordless sudo rule for `switchboard` (service restart only)
6. All project repos cloned into `$DEPLOY_ROOT/`
7. Shared venv with all project requirements installed
8. `switchboard.service` systemd unit (enabled + started)
9. nginx site config (enabled, default site removed)
10. TLS certificate via Let's Encrypt
11. UFW rules (SSH rate-limited + Nginx Full)
12. Log rotation config

After setup completes you can SSH directly into the app user for dev and troubleshooting:

```bash
ssh switchboard@your-domain.com
```

## 6. Verify service health

```bash
systemctl status switchboard --no-pager
journalctl -u switchboard -n 100 --no-pager
sudo nginx -t
curl -I --http2 https://your-domain.com
```

Expected:
- `switchboard` service: `active (running)`
- nginx config test: `syntax is ok`
- HTTPS endpoint: `HTTP/2 200`

## 7. Add per-project cron jobs

Projects that fetch or scrape data on a schedule need cron entries. SSH in as `switchboard` and edit your own crontab:

```bash
crontab -e
```

Example entry:

```cron
# Weekly background job — Monday 3:00 AM UTC
0 3 * * 1 ~/webapp-switchboard/venv/bin/python ~/My-Project/main.py scrape >> /var/log/switchboard-myproject.log 2>&1
```

All cron jobs use the shared venv at `~/webapp-switchboard/venv/bin/python`.

## 8. Deploy updates

Ensure `deploy/config.local.sh` exists on your local machine, then run:

```bash
bash deploy/deploy.sh
```

This SSHes to the server as `switchboard`, pulls all repos, reinstalls requirements, and restarts the switchboard service.

## 9. Adding a new project

1. SSH in as `switchboard` and clone the repo:
   ```bash
   git clone https://... ~/NewProject
   ```
2. Install its requirements into the shared venv:
   ```bash
   ~/webapp-switchboard/venv/bin/pip install -r ~/NewProject/requirements.txt
   ```
3. Add it to `~/webapp-switchboard/projects_local.py` on the server and locally
4. Add it to the `PROJECTS` array in `deploy/config.local.sh` (local and server)
5. Restart: `sudo systemctl restart switchboard`
6. Add any cron jobs to your crontab

---

## Troubleshooting

### certbot fails
Cause: DNS not propagated yet, or wrong `DOMAIN` in `config.local.sh`.
```bash
sudo certbot certonly --webroot -w /var/www/html -d your-domain.com
```

### Chromium package name differs by distro
On some Ubuntu/Debian versions the packages are `chromium` + `chromium-driver` rather than `chromium-browser` + `chromium-chromedriver`. Install the correct names for your distro and rerun.

### WebApp Switchboard service won't start
```bash
journalctl -u switchboard -n 200 --no-pager
```
Common causes: missing venv dependency, wrong `DEPLOY_ROOT`, permission error, or `projects_local.py` missing from the webapp-switchboard directory.

### 502 Bad Gateway from nginx
Nginx cannot reach the Gunicorn socket.
```bash
sudo systemctl status switchboard --no-pager
ls -l /run/switchboard/gunicorn.sock
```
The socket is created by Gunicorn on startup. `RuntimeDirectory=switchboard` in the service unit creates `/run/switchboard/` automatically.

### One project fails to load
WebApp Switchboard logs a warning to stderr and continues — other projects still serve normally.
```bash
journalctl -u switchboard -n 100 --no-pager | grep -i warning
```
Usual causes: missing dependency in the shared venv, `directory` name in `projects_local.py` doesn't match the actual folder, or the project's `app/blueprint.py` has an import error. The failed project will be absent from the landing page.

---

## Quick command reference

```bash
# First-time setup (on server, as root)
bash deploy/setup.sh

# SSH in for dev/troubleshooting
ssh switchboard@your-domain.com

# Health checks
systemctl status switchboard --no-pager
journalctl -u switchboard -f
sudo nginx -t

# Deploy update from local machine
bash deploy/deploy.sh

# Restart manually on server
sudo systemctl restart switchboard

# Check cron jobs
crontab -l

# Run a project CLI command manually
~/webapp-switchboard/venv/bin/python ~/My-Project/main.py --help
```
