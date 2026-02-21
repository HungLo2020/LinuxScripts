#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_SCRIPTS_DIR="$SCRIPT_DIR/miniscripts/containers"

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

if [[ ! -d "$CONTAINER_SCRIPTS_DIR" ]]; then
  echo "No container scripts directory found at: $CONTAINER_SCRIPTS_DIR"
  echo "Container setup complete."
  exit 0
fi

mapfile -t DISCOVERED_SCRIPTS < <(find "$CONTAINER_SCRIPTS_DIR" -type f -name "*.sh" | sort)

if [[ ${#DISCOVERED_SCRIPTS[@]} -eq 0 ]]; then
  echo "No container scripts found in: $CONTAINER_SCRIPTS_DIR"
  echo "Container setup complete."
  exit 0
fi

# ---------------------------
# Question Phase (prompts only)
# ---------------------------
for script_path in "${DISCOVERED_SCRIPTS[@]}"; do
  relative_script="${script_path#"$CONTAINER_SCRIPTS_DIR"/}"

  if ask_yes_no "Run $relative_script?"; then
    SELECTED_SCRIPTS+=("$script_path")
  fi
done

# ---------------------------
# Run Phase (execute selection)
# ---------------------------
if [[ ${#SELECTED_SCRIPTS[@]} -eq 0 ]]; then
  echo "No scripts selected."
  echo "Container setup complete."
  exit 0
fi

echo "Running selected container scripts..."
for script_path in "${SELECTED_SCRIPTS[@]}"; do
  if [[ ! -f "$script_path" ]]; then
    echo "Skipping missing script: $script_path"
    continue
  fi

  echo "Running: $(basename "$script_path")"
  bash "$script_path"
done

echo "Container setup complete."
