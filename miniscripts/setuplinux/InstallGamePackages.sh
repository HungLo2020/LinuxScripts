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
  "retroarch"
  "kmines"
)

echo "Installing game packages..."
for package in "${game_packages[@]}"; do
  sudo apt install -y "$package"
  echo "Installed $package"
done

echo "Done installing game packages."

# Install Vesktop (custom Discord client)
if dpkg -s vesktop >/dev/null 2>&1; then
  echo "Vesktop is already installed."
else
  echo "Installing Vesktop..."
  if ! command -v wget >/dev/null 2>&1; then
    sudo apt install -y wget
  fi
  arch="$(dpkg --print-architecture)"
  vesktop_url="https://github.com/Vencord/Vesktop/releases/latest/download/vesktop-${arch}.deb"
  wget -q -O /tmp/vesktop.deb "$vesktop_url"
  if [[ ! -s /tmp/vesktop.deb ]]; then
    echo "Error: Failed to download Vesktop package from $vesktop_url"
    rm -f /tmp/vesktop.deb
    exit 1
  fi
  sudo apt install -y /tmp/vesktop.deb
  rm -f /tmp/vesktop.deb
  echo "Installed Vesktop."
fi