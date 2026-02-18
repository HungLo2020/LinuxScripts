#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUPLINUX_SCRIPTS_DIR="$SCRIPT_DIR/miniscripts/setuplinux"
VALIDATION_SCRIPT="$SCRIPT_DIR/miniscripts/notautorun/SetupValidation.sh"

# This array stores script paths chosen during the question phase.
# The run phase executes them after all prompts are answered.
SELECTED_SCRIPTS=()
DISCOVERED_SCRIPTS=()

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

if [[ ! -f "$VALIDATION_SCRIPT" ]]; then
  echo "Validation script not found: $VALIDATION_SCRIPT"
  exit 1
fi

echo "Running setup validation..."
if ! "$VALIDATION_SCRIPT"; then
  echo "Setup validation failed. Exiting."
  exit 1
fi

# ---------------------------
# Question Phase (prompts only)
# ---------------------------
# Place setup scripts under miniscripts/setuplinux/ (including subdirectories).
# Any *.sh file found there will be prompted in sorted order, then run later
# if selected.

if [[ ! -d "$SETUPLINUX_SCRIPTS_DIR" ]]; then
  echo "No setup scripts directory found at: $SETUPLINUX_SCRIPTS_DIR"
  echo "Setup complete."
  exit 0
fi

mapfile -t DISCOVERED_SCRIPTS < <(find "$SETUPLINUX_SCRIPTS_DIR" -type f -name "*.sh" | sort)

if ask_yes_no "Run all scripts?"; then
  SELECTED_SCRIPTS=("${DISCOVERED_SCRIPTS[@]}")
else
  for script_path in "${DISCOVERED_SCRIPTS[@]}"; do
    relative_script="${script_path#"$SETUPLINUX_SCRIPTS_DIR"/}"
    if ask_yes_no "Run $relative_script?"; then
      SELECTED_SCRIPTS+=("$script_path")
    fi
  done
fi

# Run apt update once at the start to ensure we have the latest package info after script selection
echo "Updating package lists..."
sudo apt update
echo "Upgrading installed packages..."
sudo apt upgrade -y

# ---------------------------
# Run Phase (execute selection)
# ---------------------------
if [[ ${#SELECTED_SCRIPTS[@]} -eq 0 ]]; then
  echo "No scripts selected."
  echo "Setup complete."
  exit 0
fi

echo "Running selected scripts..."
for script_path in "${SELECTED_SCRIPTS[@]}"; do
  if [[ ! -f "$script_path" ]]; then
    echo "Skipping missing script: $script_path"
    continue
  fi

  echo "Running: $(basename "$script_path")"
  "$script_path"
done

echo "Setup complete."