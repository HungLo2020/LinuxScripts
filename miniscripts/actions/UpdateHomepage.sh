#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="/home/matt/Documents/Repos/LinuxScripts"
HOMEPAGE_SCRIPT="miniscripts/containers/RunHomepageContainer.sh"
LOCK_FILE="/tmp/linuxscripts-update-homepage.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if [[ ! -d "$REPO_DIR" ]]; then
  log "Error: expected repo directory not found: $REPO_DIR"
  exit 1
fi

cd "$REPO_DIR"

if [[ ! -f "$HOMEPAGE_SCRIPT" ]]; then
  log "Error: homepage script not found at $REPO_DIR/$HOMEPAGE_SCRIPT"
  exit 1
fi

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Another homepage update action is already running."
  exit 0
fi

log "Pulling latest repository changes..."
git pull --ff-only

log "Running homepage container update script..."
bash "$HOMEPAGE_SCRIPT"

log "Homepage update action complete."
