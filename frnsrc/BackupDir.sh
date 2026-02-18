#!/bin/bash

# === Configuration ===
DEST_DIR="/home/matt/Downloads"             # Where to move the zip file
EXCLUDES=("node_modules" "*.tmp" ".git")     # Add file or folder names/patterns to exclude

# === Setup ===
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
basename="$(basename "$script_dir")"
timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
zip_name="${basename}_${timestamp}.zip"
temp_zip_path="/tmp/$zip_name"

# === Build the exclusion list for zip ===
exclude_args=()
for pattern in "${EXCLUDES[@]}"; do
	exclude_args+=("-x" "$pattern")
done

# === Create the zip ===
cd "$script_dir" || exit 1
zip -r "$temp_zip_path" . "${exclude_args[@]}"
echo "📦 Created zip: $temp_zip_path"

# === Move it to the destination ===
mkdir -p "$DEST_DIR"
mv "$temp_zip_path" "$DEST_DIR/"
echo "✅ Moved to: $DEST_DIR/$zip_name"
