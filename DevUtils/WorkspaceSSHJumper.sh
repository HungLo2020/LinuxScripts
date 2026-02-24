#!/usr/bin/env bash

set -euo pipefail

sudo apt update

sudo apt install -y curl
sudo apt install -y openssh-client
sudo apt install -y tailscale

echo "Installing Tailscale..."
if [[ "$EUID" -eq 0 ]]; then
  curl -fsSL https://tailscale.com/install.sh | sh
else
  curl -fsSL https://tailscale.com/install.sh | sudo sh
fi