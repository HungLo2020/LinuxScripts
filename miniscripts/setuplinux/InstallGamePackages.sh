#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADD_REPOS_SCRIPT="$SCRIPT_DIR/AddRepos.sh"

if [[ ! -x "$ADD_REPOS_SCRIPT" ]]; then
  echo "Error: Required script not found or not executable: $ADD_REPOS_SCRIPT"
  exit 1
fi

echo "Running AddRepos.sh before game package installs..."
"$ADD_REPOS_SCRIPT"

game_packages=(
  "steam"
  "kmines"
)

echo "Installing game packages..."
for package in "${game_packages[@]}"; do
  sudo apt install -y "$package"
  echo "Installed $package"
done

echo "Done installing game packages."