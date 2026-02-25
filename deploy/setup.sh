#!/usr/bin/env bash
# One-time bootstrap for WebApp Switchboard on a fresh Ubuntu VPS.
# Run as root: sudo bash deploy/setup.sh
set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

CONFIG="$(dirname "${BASH_SOURCE[0]}")/config.local.sh"
if [ ! -f "$CONFIG" ]; then
    echo "ERROR: $CONFIG not found."
    echo "Copy deploy/config.template.sh to deploy/config.local.sh and fill in your values."
    exit 1
fi
# shellcheck source=deploy/config.template.sh
source "$CONFIG"

# =============================================================================
# Derived paths
# =============================================================================

SWITCHBOARD_DIR="$DEPLOY_ROOT/webapp-switchboard"
VENV="$SWITCHBOARD_DIR/venv"

# =============================================================================
# 1. Swap file (recommended for 1 GB RAM hosts)
# =============================================================================

if [ ! -f /swapfile ]; then
    echo "==> Creating 2 GB swap file"
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    # Use swap only under real memory pressure; preserve inode cache
    sysctl -w vm.swappiness=10
    sysctl -w vm.vfs_cache_pressure=50
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
    echo 'vm.vfs_cache_pressure=50' >> /etc/sysctl.conf
    echo "  Swap active: $(swapon --show)"
else
    echo "==> Swap file already exists, skipping"
fi

# =============================================================================
# 2. System packages
# =============================================================================

echo "==> Installing system packages"
apt-get update -qq
apt-get install -y \
    python3 python3-pip python3-venv \
    nginx certbot python3-certbot-nginx \
    git ufw curl wget

# Chromium + ChromeDriver (required by projects that use Selenium scraping)
echo "==> Installing Chromium and ChromeDriver"
apt-get install -y chromium-browser chromium-chromedriver || \
    apt-get install -y chromium chromium-driver || \
    echo "WARNING: Could not install Chromium. Install manually if scraping is needed."

# =============================================================================
# 3. App user (SSH login)
# =============================================================================

echo "==> Creating app user: $SWITCHBOARD_USER"
id "$SWITCHBOARD_USER" &>/dev/null || \
    useradd --create-home --shell /bin/bash "$SWITCHBOARD_USER"

echo "==> Granting $SWITCHBOARD_USER passwordless sudo for service management"
echo "$SWITCHBOARD_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart switchboard, /usr/bin/systemctl restart switchboard, /bin/systemctl status switchboard, /usr/bin/systemctl status switchboard" \
    > /etc/sudoers.d/switchboard-deploy
chmod 440 /etc/sudoers.d/switchboard-deploy

echo "==> Setting up SSH authorized_keys for $SWITCHBOARD_USER"
SSH_DIR="/home/$SWITCHBOARD_USER/.ssh"
mkdir -p "$SSH_DIR"
if [ -f /root/.ssh/authorized_keys ] && [ ! -f "$SSH_DIR/authorized_keys" ]; then
    cp /root/.ssh/authorized_keys "$SSH_DIR/authorized_keys"
    echo "  Copied root's authorized_keys — SSH in as $SWITCHBOARD_USER with your existing key"
else
    touch "$SSH_DIR/authorized_keys"
    echo "  Add your public key to $SSH_DIR/authorized_keys"
fi
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$SWITCHBOARD_USER:$SWITCHBOARD_USER" "$SSH_DIR"

# =============================================================================
# 4. Clone all repos
# =============================================================================

echo "==> Cloning repositories into $DEPLOY_ROOT"
mkdir -p "$DEPLOY_ROOT"

for entry in "${PROJECTS[@]}"; do
    dir="${entry%%|*}"
    url="${entry##*|}"
    dest="$DEPLOY_ROOT/$dir"
    if [ -d "$dest/.git" ]; then
        echo "  $dir — already cloned, pulling latest"
        chown -R "$SWITCHBOARD_USER:$SWITCHBOARD_USER" "$dest"
        sudo -u "$SWITCHBOARD_USER" git -C "$dest" pull --ff-only
    else
        echo "  $dir — cloning from $url"
        git clone "$url" "$dest"
        chown -R "$SWITCHBOARD_USER:$SWITCHBOARD_USER" "$dest"
    fi
done

# =============================================================================
# 5. Shared virtual environment
# =============================================================================

echo "==> Creating shared venv at $VENV"
python3 -m venv "$VENV"

echo "==> Installing dependencies from all projects"
for entry in "${PROJECTS[@]}"; do
    dir="${entry%%|*}"
    req="$DEPLOY_ROOT/$dir/requirements.txt"
    if [ -f "$req" ]; then
        echo "  Installing $dir/requirements.txt"
        "$VENV/bin/pip" install --quiet -r "$req"
    fi
done

chown -R "$SWITCHBOARD_USER:$SWITCHBOARD_USER" "$VENV"

# =============================================================================
# 6. systemd service
# =============================================================================

echo "==> Installing systemd service"
SERVICE_SRC="$SWITCHBOARD_DIR/deploy/switchboard.service"
SERVICE_DEST="/etc/systemd/system/switchboard.service"

sed \
    -e "s|{{SWITCHBOARD_USER}}|$SWITCHBOARD_USER|g" \
    -e "s|{{DEPLOY_ROOT}}|$DEPLOY_ROOT|g" \
    "$SERVICE_SRC" > "$SERVICE_DEST"

systemctl daemon-reload
systemctl enable switchboard
systemctl restart switchboard

# =============================================================================
# 7. nginx
# =============================================================================

echo "==> Installing temporary HTTP-only nginx config for ACME challenge"
cat > /etc/nginx/sites-available/switchboard <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF

ln -sf /etc/nginx/sites-available/switchboard /etc/nginx/sites-enabled/switchboard
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

# =============================================================================
# 8. TLS via Let's Encrypt
# =============================================================================

echo "==> Obtaining TLS certificate for $DOMAIN"
certbot certonly --webroot -w /var/www/html \
    -d "$DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL" || \
    echo "WARNING: certbot failed. Run manually: sudo certbot certonly --webroot -w /var/www/html -d $DOMAIN"

# =============================================================================
# 8b. nginx — full config (TLS cert now exists)
# =============================================================================

echo "==> Installing full nginx config"
NGINX_SRC="$SWITCHBOARD_DIR/deploy/nginx.conf"
NGINX_DEST="/etc/nginx/sites-available/switchboard"

sed \
    -e "s|{{DOMAIN}}|$DOMAIN|g" \
    -e "s|{{DEPLOY_ROOT}}|$DEPLOY_ROOT|g" \
    "$NGINX_SRC" > "$NGINX_DEST"

nginx -t
systemctl reload nginx

# =============================================================================
# 9. Firewall
# =============================================================================

echo "==> Configuring UFW"
ufw default deny incoming
ufw default allow outgoing
ufw limit OpenSSH
ufw allow "Nginx Full"
ufw --force enable

# =============================================================================
# 10. Log rotation
# =============================================================================

echo "==> Configuring log rotation"
cat > /etc/logrotate.d/switchboard <<EOF
/var/log/switchboard-*.log {
    weekly
    missingok
    rotate 8
    compress
    delaycompress
    notifempty
}
EOF

# =============================================================================
# Done
# =============================================================================

echo ""
echo "==> Setup complete"
echo ""
echo "Service status:"
systemctl status switchboard --no-pager || true
echo ""
echo "Next steps:"
echo "  1. Verify:  sudo systemctl status switchboard"
echo "              sudo journalctl -u switchboard -n 50 --no-pager"
echo "              curl -I --http2 https://$DOMAIN"
echo ""
echo "  2. Add per-project cron jobs as $SWITCHBOARD_USER. Example:"
echo "       0 3 * * 1 $VENV/bin/python $DEPLOY_ROOT/My-Project/main.py scrape >> /var/log/switchboard-myproject.log 2>&1"
echo ""
echo "     Run: sudo crontab -u $SWITCHBOARD_USER -e"
echo ""
echo "  3. See VPS_SETUP.md for the full operational guide."
