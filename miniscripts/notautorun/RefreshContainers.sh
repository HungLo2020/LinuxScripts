#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP_DIR="$REPO_ROOT/miniscripts/setuplinux"

echo "=========================================="
echo " RefreshContainers"
echo "=========================================="
echo ""

# ─── Git Pull ─────────────────────────────────────────────────────────────────

# When this script is run as root (via the ttyd systemd service) but the repo
# is owned by a regular user, Git 2.35.2+ refuses to operate with "dubious
# ownership". Mark the repo as safe for the root user before pulling.
git config --global --add safe.directory "$REPO_ROOT"

echo "Pulling latest changes from remote..."
git -C "$REPO_ROOT" pull
echo "Repository is up to date."
echo ""

# ─── Refresh Portainer ────────────────────────────────────────────────────────

echo "=========================================="
echo " Refreshing Portainer..."
echo "=========================================="
bash "$SETUP_DIR/SetupHomepageContainer.sh"
echo ""

# ─── Refresh Homepage Dashboard ───────────────────────────────────────────────

echo "=========================================="
echo " Refreshing Homepage Dashboard..."
echo "=========================================="
bash "$SETUP_DIR/SetupDashboardContainer.sh"
echo ""

echo "=========================================="
echo " All containers refreshed successfully."
echo "=========================================="
