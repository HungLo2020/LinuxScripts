#!/usr/bin/env bash

set -euo pipefail

DEST_DIR="/home/matt/OneDrive/Apps/Programming/LinuxScripts/"
EXCLUDES=("node_modules" "*.tmp" ".git")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_name="$(basename "$script_dir")"
timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
zip_name="${repo_name}_${timestamp}.zip"
temp_zip_path="/tmp/$zip_name"

exclude_args=()
for pattern in "${EXCLUDES[@]}"; do
  exclude_args+=("-x" "$pattern")
done

cd "$script_dir"
zip -r "$temp_zip_path" . "${exclude_args[@]}"
echo "Created zip: $temp_zip_path"

mkdir -p "$DEST_DIR"
mv "$temp_zip_path" "$DEST_DIR"
echo "Moved to: $DEST_DIR$zip_name"