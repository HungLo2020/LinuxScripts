#!/usr/bin/env bash

set -euo pipefail

flatpak_packages=(
  "bottles"
  "flatseal"
  "MissionCenter"
)

echo "Installing flatpak..."
sudo apt install -y flatpak

echo "Adding Flathub remote..."
sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

echo "Installing Flatpak packages..."
for package in "${flatpak_packages[@]}"; do
  sudo flatpak install -y "$package"
  echo "Installed $package"
done

echo "Done installing Flatpak packages."