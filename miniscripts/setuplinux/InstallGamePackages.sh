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

# Install Vesktop - a custom Discord client built on Vencord
# Skip if vesktop is already present on the system
if dpkg -s vesktop >/dev/null 2>&1; then
  echo "Vesktop is already installed."
else
  echo "Installing Vesktop..."
  # Ensure wget is available for downloading the package
  if ! command -v wget >/dev/null 2>&1; then
    sudo apt install -y wget
  fi
  # Build the download URL using the system architecture (e.g. amd64, arm64)
  # The 'latest' redirect always points to the newest release automatically
  arch="$(dpkg --print-architecture)"
  vesktop_url="https://github.com/Vencord/Vesktop/releases/latest/download/vesktop-${arch}.deb"
  wget -q -O /tmp/vesktop.deb "$vesktop_url"
  # Verify the download succeeded before attempting install
  if [[ ! -s /tmp/vesktop.deb ]]; then
    echo "Error: Failed to download Vesktop package from $vesktop_url"
    rm -f /tmp/vesktop.deb
    exit 1
  fi
  # Install via apt (instead of dpkg) so dependencies are resolved automatically
  sudo apt install -y /tmp/vesktop.deb
  rm -f /tmp/vesktop.deb
  echo "Installed Vesktop."
fi

echo "Done installing game packages."