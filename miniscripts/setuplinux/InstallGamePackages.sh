#!/usr/bin/env bash

set -euo pipefail

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