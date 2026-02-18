#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_CONF="$REPO_ROOT/resources/variety.conf"
TARGET_DIR="$HOME/.config/variety"
TARGET_CONF="$TARGET_DIR/variety.conf"

echo "Installing Variety..."
sudo apt update
sudo apt install -y variety

if [[ ! -f "$SOURCE_CONF" ]]; then
  echo "Error: Could not find source config at $SOURCE_CONF"
  exit 1
fi

echo "Copying variety.conf to $TARGET_CONF..."
mkdir -p "$TARGET_DIR"
cp "$SOURCE_CONF" "$TARGET_CONF"

echo "Done. Variety is installed and config copied."