#!/usr/bin/env bash

set -euo pipefail

ask_yes_no() {
  local prompt="$1"
  local answer

  while true; do
    read -r -p "$prompt (y/n): " answer
    case "$answer" in
      [Yy]) return 0 ;;
      [Nn]) return 1 ;;
      *) echo "Please enter y or n." ;;
    esac
  done
}

current_driver_version="Not detected"
current_driver_package="Not detected"
recommended_driver_package="Not detected"

if command -v nvidia-smi >/dev/null 2>&1; then
  current_driver_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
  if [[ -z "$current_driver_version" ]]; then
    current_driver_version="Installed, but version could not be read"
  fi
else
  current_driver_version="NVIDIA driver command not found (nvidia-smi missing)"
fi

current_driver_package="$(dpkg -l 'nvidia-driver-*' 2>/dev/null | awk '/^ii/ {print $2}' | sort -V | tail -n1 || true)"
if [[ -z "$current_driver_package" ]]; then
  current_driver_package="No nvidia-driver-* package currently installed"
fi

if command -v ubuntu-drivers >/dev/null 2>&1; then
  recommended_driver_package="$(ubuntu-drivers devices 2>/dev/null | grep -oE 'nvidia-driver-[0-9]+' | tail -n1 || true)"
  if [[ -z "$recommended_driver_package" ]]; then
    recommended_driver_package="Not found by ubuntu-drivers"
  fi
fi

latest_proprietary_package="$(apt-cache search --names-only '^nvidia-driver-[0-9]+$' | awk '{print $1}' | sort -V | tail -n1 || true)"

if [[ -z "$latest_proprietary_package" ]]; then
  echo "Could not determine latest proprietary NVIDIA package from apt cache."
  echo "Try running: sudo apt update"
  exit 1
fi

echo "Current NVIDIA driver version: $current_driver_version"
echo "Current NVIDIA driver package: $current_driver_package"
echo "Recommended NVIDIA package (ubuntu-drivers): $recommended_driver_package"
echo "Latest proprietary NVIDIA package available (apt): $latest_proprietary_package"

if [[ "$current_driver_package" == "$latest_proprietary_package" ]]; then
  echo "You already appear to be on the latest proprietary NVIDIA package."
  exit 0
fi

if ask_yes_no "Would you like to install/update to $latest_proprietary_package?"; then
  echo "Updating apt cache and installing $latest_proprietary_package..."
  sudo apt update
  sudo apt install -y "$latest_proprietary_package"
  echo "Done. A reboot may be required for driver changes to fully apply."
else
  echo "Skipping NVIDIA driver update."
fi