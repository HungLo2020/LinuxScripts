#!/usr/bin/env bash

set -euo pipefail

TARGET_USER="${SUDO_USER:-$(id -un)}"

RCLONE_BLOCK_BEGIN="# >>> LinuxScripts OneDriveRcloneSetup >>>"
RCLONE_BLOCK_END="# <<< LinuxScripts OneDriveRcloneSetup <<<"
SERVER_BLOCK_BEGIN="# >>> LinuxScripts OneDriveServer >>>"
SERVER_BLOCK_END="# <<< LinuxScripts OneDriveServer <<<"

removed_service_files=()

run_privileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

cleanup_rclone_mount_service() {
  local service_name="rclone-mount.service"
  local service_paths=(
    "/etc/systemd/system/${service_name}"
    "/lib/systemd/system/${service_name}"
    "/usr/lib/systemd/system/${service_name}"
  )

  echo "Checking for ${service_name}..."

  run_privileged systemctl stop "$service_name" 2>/dev/null || true
  run_privileged systemctl disable "$service_name" 2>/dev/null || true

  local path
  for path in "${service_paths[@]}"; do
    if run_privileged test -e "$path"; then
      run_privileged rm -f "$path"
      removed_service_files+=("$path")
    fi
  done

  run_privileged systemctl daemon-reload
  run_privileged systemctl reset-failed "$service_name" 2>/dev/null || true
}

if ! command -v crontab >/dev/null 2>&1; then
  echo "Error: crontab command is not available."
  exit 1
fi

if [[ "$(id -u)" -eq 0 ]]; then
  current_crontab="$(crontab -u "$TARGET_USER" -l 2>/dev/null || true)"
else
  current_crontab="$(crontab -l 2>/dev/null || true)"
fi

kept_file="$(mktemp)"
removed_file="$(mktemp)"
trap 'rm -f "$kept_file" "$removed_file"' EXIT

printf '%s\n' "$current_crontab" | awk \
  -v r_begin="$RCLONE_BLOCK_BEGIN" \
  -v r_end="$RCLONE_BLOCK_END" \
  -v s_begin="$SERVER_BLOCK_BEGIN" \
  -v s_end="$SERVER_BLOCK_END" \
  -v removed_out="$removed_file" \
  -v kept_out="$kept_file" '
  BEGIN {
    in_rclone_block = 0
    in_server_block = 0
  }

  {
    line = $0

    if (line == r_begin) {
      in_rclone_block = 1
      print line >> removed_out
      next
    }

    if (line == r_end) {
      in_rclone_block = 0
      print line >> removed_out
      next
    }

    if (line == s_begin) {
      in_server_block = 1
      print line >> kept_out
      next
    }

    if (line == s_end) {
      in_server_block = 0
      print line >> kept_out
      next
    }

    if (in_rclone_block == 1) {
      print line >> removed_out
      next
    }

    if (in_server_block == 1) {
      print line >> kept_out
      next
    }

    if (line ~ /OneDrive:Media\/Wallpapers/ || line ~ /onedrive-wallpapers-bisync/ || line ~ /LinuxScripts OneDriveRcloneSetup/) {
      print line >> removed_out
      next
    }

    print line >> kept_out
  }
'

removed_count=0
if [[ -s "$removed_file" ]]; then
  removed_count="$(wc -l < "$removed_file" | tr -d '[:space:]')"
fi

if [[ -n "$current_crontab" ]]; then
  new_crontab="$(cat "$kept_file")"
  if [[ -n "$new_crontab" ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
      printf '%s\n' "$new_crontab" | crontab -u "$TARGET_USER" -
    else
      printf '%s\n' "$new_crontab" | crontab -
    fi
  else
    if [[ "$(id -u)" -eq 0 ]]; then
      crontab -u "$TARGET_USER" -r
    else
      crontab -r
    fi
  fi
else
  if [[ "$removed_count" == "0" ]]; then
    echo "No crontab entries found for user '$TARGET_USER'."
  else
    echo "Warning: detected removable entries but could not load current crontab for '$TARGET_USER'."
  fi
fi

if [[ "$removed_count" == "0" ]]; then
  echo "No OneDriveRcloneSetup cron entries found."
else
  echo "Removed ${removed_count} OneDriveRcloneSetup-related crontab line(s):"
  cat "$removed_file"
fi

cleanup_rclone_mount_service

if [[ ${#removed_service_files[@]} -eq 0 ]]; then
  echo "No rclone-mount.service file found in standard systemd locations."
else
  echo "Removed rclone-mount.service file(s):"
  printf '%s\n' "${removed_service_files[@]}"
fi

echo "Cleanup complete."
