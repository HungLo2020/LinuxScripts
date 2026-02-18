#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE_REPOS_SCRIPT="$SCRIPT_DIR/../notautorun/CreateReposDir.sh"
REPOS_DIR="$HOME/Documents/Repos"
MATTMC_DIR="$REPOS_DIR/MattMC"
MATTMC_REPO_URL="https://github.com/HungLo2020/MattMC.git"

echo "Ensuring repos directory exists..."
if [[ ! -x "$CREATE_REPOS_SCRIPT" ]]; then
  echo "Error: Required script not found or not executable: $CREATE_REPOS_SCRIPT"
  exit 1
fi
"$CREATE_REPOS_SCRIPT"

if [[ -d "$MATTMC_DIR" ]]; then
  echo "MattMC directory already exists: $MATTMC_DIR"
else
  echo "Cloning MattMC into $MATTMC_DIR..."
  git clone "$MATTMC_REPO_URL" "$MATTMC_DIR"
fi

if snap list intellij-idea >/dev/null 2>&1; then
  echo "intellij-idea is already installed via snap."
else
  echo "Installing intellij-idea via snap..."
  sudo snap install intellij-idea --classic
fi

echo "InstallMattMCDev complete."