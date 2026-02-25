# WebApp Switchboard deployment configuration template.
# Copy this file to deploy/config.local.sh and fill in your values.
# config.local.sh is gitignored and never committed.

SWITCHBOARD_USER="switchboard"
DEPLOY_ROOT="/home/$SWITCHBOARD_USER"
DOMAIN="your-domain.com"
CERTBOT_EMAIL="you@example.com"
SERVER="$SWITCHBOARD_USER@$DOMAIN"

# Projects to clone: "directory_name|git_url"
# directory_name MUST match the 'directory' field in projects_local.py.
# The webapp-switchboard repo itself must be first.
PROJECTS=(
    "webapp-switchboard|https://github.com/hmorris94/webapp-switchboard.git"
    "My-Project-A|https://github.com/YOUR_USER/project-a.git"
    "My-Project-B|https://github.com/YOUR_USER/project-b.git"
)
