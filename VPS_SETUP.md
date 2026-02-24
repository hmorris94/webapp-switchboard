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

## 3. First login and hardening

```bash
ssh root@YOUR_VPS_IP
```

Recommended: create a non-root deploy user:

```bash
adduser deployer
usermod -aG sudo deployer
mkdir -p /home/deployer/.ssh
cp /root/.ssh/authorized_keys /home/deployer/.ssh/
chown -R deployer:deployer /home/deployer/.ssh
chmod 700 /home/deployer/.ssh && chmod 600 /home/deployer/.ssh/authorized_keys
```

Reconnect as `deployer` and use `sudo` for admin actions.

## 4. Prepare local config

`deploy/config.local.sh` is gitignored and must be created on your **local machine**. `deploy.sh` sources it to get the SSH target, deploy root, and project list before connecting to the server.

```bash
cp deploy/config.template.sh deploy/config.local.sh
$EDITOR deploy/config.local.sh
```

Fill in all variables — `SWITCHBOARD_USER`, `DEPLOY_ROOT`, `DOMAIN`, `CERTBOT_EMAIL`, `DEPLOY_USER`, and the `PROJECTS` array. The `directory_name` part of each entry (before `|`) must match the `"directory"` field in `projects_local.py`. `DEPLOY_USER` is the SSH user that runs `deploy.sh`; `setup.sh` grants it passwordless sudo for service restarts.

The server also needs its own copy of `config.local.sh` so that `setup.sh` can run — copy it over in step 5. `projects_local.py` is server-only and is also created in step 5.

## 5. Bootstrap the server

Clone the repo on the server and place the gitignored config files:

```bash
sudo git clone https://github.com/hmorris94/webapp-switchboard.git /opt/webapp-switchboard
```

Copy `config.local.sh` from your local machine (it contains the same values `setup.sh` needs):

```bash
scp deploy/config.local.sh deployer@your-domain.com:/opt/webapp-switchboard/deploy/config.local.sh
```

Then on the server, create `projects_local.py`:

```bash
cd /opt/webapp-switchboard
sudo cp projects_template.py projects_local.py
sudo $EDITOR projects_local.py
```

Then run the bootstrap script as root:

```bash
sudo bash deploy/setup.sh
```

This installs:
1. 2 GB swap file (with `vm.swappiness=10`)
2. System packages (Python 3, nginx, certbot, git, ufw)
3. Chromium + ChromeDriver (for projects that use Selenium scraping)
4. `switchboard` OS user
5. Passwordless sudo rule for `DEPLOY_USER` (service restart only)
6. All project repos cloned into `$DEPLOY_ROOT/`
7. Shared venv with all project requirements installed
8. `switchboard.service` systemd unit (enabled + started)
9. nginx site config (enabled, default site removed)
10. TLS certificate via Let's Encrypt
11. UFW rules (SSH rate-limited + Nginx Full)
12. Log rotation config

## 6. Verify service health

```bash
sudo systemctl status switchboard --no-pager
sudo journalctl -u switchboard -n 100 --no-pager
sudo nginx -t
curl -I --http2 https://your-domain.com
```

Expected:
- `switchboard` service: `active (running)`
- nginx config test: `syntax is ok`
- HTTPS endpoint: `HTTP/2 200`

## 7. Add per-project cron jobs

Projects that fetch or scrape data on a schedule need cron entries under the `switchboard` user:

```bash
sudo crontab -u switchboard -e
```

Example entry:

```cron
# Weekly background job — Monday 3:00 AM UTC
0 3 * * 1 /opt/webapp-switchboard/venv/bin/python /opt/My-Project/main.py scrape >> /var/log/switchboard-myproject.log 2>&1
```

All cron jobs use the shared venv at `/opt/webapp-switchboard/venv/bin/python`.

## 8. Deploy updates

Ensure `deploy/config.local.sh` exists on your local machine, then run:

```bash
bash deploy/deploy.sh
```

This SSHes to the server, pulls all repos, reinstalls requirements, and restarts the switchboard service.

## 9. Adding a new project

1. On the server: clone the repo and set ownership
   ```bash
   sudo git clone https://... /opt/NewProject
   sudo chown -R switchboard:switchboard /opt/NewProject
   ```
2. Install its requirements into the shared venv:
   ```bash
   sudo /opt/webapp-switchboard/venv/bin/pip install -r /opt/NewProject/requirements.txt
   ```
3. Add it to `projects_local.py` on the server and locally
4. Add it to the `PROJECTS` array in `deploy/config.local.sh` (local and server)
5. Restart: `sudo systemctl restart switchboard`
6. Add any cron jobs to the `switchboard` user's crontab

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
sudo journalctl -u switchboard -n 200 --no-pager
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
sudo journalctl -u switchboard -n 100 --no-pager | grep -i warning
```
Usual causes: missing dependency in the shared venv, `directory` name in `projects_local.py` doesn't match the actual folder, or the project's `app/blueprint.py` has an import error. The failed project will be absent from the landing page.

---

## Quick command reference

```bash
# First-time setup (on server)
sudo bash deploy/setup.sh

# Health checks
sudo systemctl status switchboard --no-pager
sudo journalctl -u switchboard -f
sudo nginx -t

# Deploy update from local machine
bash deploy/deploy.sh

# Restart manually on server
sudo systemctl restart switchboard

# Check cron jobs
sudo crontab -u switchboard -l

# Run a project CLI command manually on the server
sudo -u switchboard /opt/webapp-switchboard/venv/bin/python /opt/My-Project/main.py --help
```
