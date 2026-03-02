#!/usr/bin/env bash
# Rolling update — run from your local machine to deploy the latest code.
# Usage: bash deploy/deploy.sh
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
source <(sed 's/\r//' "$CONFIG")

# =============================================================================

# Extract directory names from PROJECTS (strip |url suffix)
PROJECT_DIRS=()
for _entry in "${PROJECTS[@]}"; do
    PROJECT_DIRS+=("${_entry%%|*}")
done

VENV="$DEPLOY_ROOT/webapp-switchboard/venv"

echo "==> Deploying to $SERVER"

ssh "$SERVER" bash -s -- "$DEPLOY_ROOT" "$VENV" "${PROJECT_DIRS[@]}" <<'REMOTE'
set -euo pipefail
DEPLOY_ROOT="$1"; VENV="$2"
shift 2; PROJECTS=("$@")

echo "--- Pulling latest code"
for dir in "${PROJECTS[@]}"; do
    dest="$DEPLOY_ROOT/$dir"
    if [ -d "$dest/.git" ]; then
        echo "  git pull: $dir"
        git -C "$dest" pull --ff-only
    else
        echo "  SKIP (not cloned): $dir"
    fi
done

echo "--- Reinstalling dependencies"
for dir in "${PROJECTS[@]}"; do
    req="$DEPLOY_ROOT/$dir/requirements.txt"
    if [ -f "$req" ]; then
        echo "  pip install: $dir"
        "$VENV/bin/pip" install --quiet -r "$req"
    fi
done

echo "--- Rebuilding frontend assets"
for dir in "${PROJECTS[@]}"; do
    pkg="$DEPLOY_ROOT/$dir/package.json"
    if [ -f "$pkg" ]; then
        echo "  npm install + build: $dir"
        npm --prefix "$DEPLOY_ROOT/$dir" install --silent
        npm --prefix "$DEPLOY_ROOT/$dir" run build --silent
    fi
done

echo "--- Restarting switchboard service"
sudo systemctl restart switchboard
sleep 2
sudo systemctl status switchboard --no-pager
REMOTE

echo ""
echo "==> Deploy complete"
