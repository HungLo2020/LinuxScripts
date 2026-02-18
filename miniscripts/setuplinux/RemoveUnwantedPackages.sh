#!/usr/bin/env bash

set -euo pipefail

unwanted_packages=(
  "plasma-vault"
  "krdc"
  "neochat"
  "konversation"
  "skanlite"
  "akregator"
  "dragonplayer"
  "gimp"
  "juk"
  "kdeconnect"
  "kmail"
  "kmouth"
  "konqueror"
  "knotes"
  "korganizer"
  "kwrite"
)

echo "Removing unwanted packages..."
for package in "${unwanted_packages[@]}"; do
  sudo apt remove -y "$package"
  echo "Removed $package"
done

echo "Done removing unwanted packages."