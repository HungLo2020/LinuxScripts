#!/usr/bin/env bash

set -euo pipefail

echo "Adding multiverse repository..."
sudo add-apt-repository multiverse -y

echo "Updating package lists..."
sudo apt update

echo "Done. Multiverse repository is enabled."