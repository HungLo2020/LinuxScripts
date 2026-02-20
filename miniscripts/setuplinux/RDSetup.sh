#!/usr/bin/env bash

set -euo pipefail

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

# Install curl
sudo apt update
sudo apt install -y curl

if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
  echo "Error: Could not determine home directory for user '$TARGET_USER'."
  exit 1
fi

echo "Installing Tailscale..."
if [[ "$EUID" -eq 0 ]]; then
  curl -fsSL https://tailscale.com/install.sh | sh
else
  curl -fsSL https://tailscale.com/install.sh | sudo sh
fi

echo "Bringing Tailscale up..."
sudo tailscale up

echo "Downloading latest RustDesk release..."
RUSTDESK_DOWNLOAD_DIR="$TARGET_HOME/Downloads/RustDesk"
mkdir -p "$RUSTDESK_DOWNLOAD_DIR"
chown -R "$TARGET_USER":"$TARGET_USER" "$RUSTDESK_DOWNLOAD_DIR"

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required to download RustDesk."
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required to parse RustDesk release metadata."
  exit 1
fi

RUSTDESK_URL="$(curl -fsSL https://api.github.com/repos/rustdesk/rustdesk/releases/latest | python3 -c 'import sys, json; data=json.load(sys.stdin); assets=data.get("assets", []);
for asset in assets:
    name=asset.get("name", "")
    if name.endswith(".deb") and ("amd64" in name or "x86_64" in name):
        print(asset.get("browser_download_url", ""));
        break')"

if [[ -z "$RUSTDESK_URL" ]]; then
  echo "Error: Could not find a RustDesk .deb asset in the latest release."
  exit 1
fi

RUSTDESK_FILE="$RUSTDESK_DOWNLOAD_DIR/$(basename "$RUSTDESK_URL")"
curl -fL "$RUSTDESK_URL" -o "$RUSTDESK_FILE"
chown "$TARGET_USER":"$TARGET_USER" "$RUSTDESK_FILE"

echo "Downloaded RustDesk package to: $RUSTDESK_FILE"

echo "Installing RustDesk..."
if [[ "$EUID" -eq 0 ]]; then
  apt install -y "$RUSTDESK_FILE"
else
  sudo apt install -y "$RUSTDESK_FILE"
fi

echo "Cleaning up RustDesk installer files..."
rm -f "$RUSTDESK_FILE"
rmdir "$RUSTDESK_DOWNLOAD_DIR" 2>/dev/null || true

echo "RustDesk installed and cleanup complete."

echo "Installing OpenSSH Server..."
sudo apt update
sudo apt install -y openssh-server
echo "Enabling and starting sshd service..."
sudo systemctl enable ssh
sudo systemctl start ssh
echo "Setup complete. Tailscale, RustDesk, and OpenSSH Server are installed and running."