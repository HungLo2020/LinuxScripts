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
