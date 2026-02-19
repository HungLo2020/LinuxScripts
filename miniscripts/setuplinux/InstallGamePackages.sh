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

# Remove Discord if currently installed, then replace with Vesktop
echo "Checking for existing Discord installations..."
if dpkg -s discord >/dev/null 2>&1; then
  echo "Removing Discord (deb)..."
  sudo apt remove -y discord
fi
if snap list discord >/dev/null 2>&1; then
  echo "Removing Discord (snap)..."
  sudo snap remove discord
fi
if flatpak list --app --columns=application 2>/dev/null | grep -q '^com.discordapp.Discord$'; then
  echo "Removing Discord (flatpak)..."
  sudo flatpak uninstall -y com.discordapp.Discord
fi

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