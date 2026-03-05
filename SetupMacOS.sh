#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BW_MASTER_PASSWORD_FILE="$SCRIPT_DIR/.bw_master_password"

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_UID="$(id -u "$TARGET_USER")"

SMB_SERVER_IP="100.72.33.98"
SMB_SHARE_NAME="storage"
SMB_MOUNT_POINT="/mnt/storage"

NSMB_CONF_PATH="/etc/nsmb.conf"
LAUNCHD_LABEL="com.hunglo.storage-smb-mount"
LAUNCHD_PLIST_PATH="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"
HELPER_SCRIPT_PATH="/usr/local/sbin/storage-smb-mount-macos.sh"

BITWARDEN_ITEM_NAME="PCPassword"
SMB_PASSWORD=""

run_as_target_user() {
  if [[ "$(id -un)" == "$TARGET_USER" ]]; then
    "$@"
  else
    sudo -H -u "$TARGET_USER" "$@"
  fi
}

bw_exec() {
  if [[ "$(id -un)" == "$TARGET_USER" ]]; then
    BW_SESSION="${BW_SESSION:-}" bw "$@"
  else
    sudo -H -u "$TARGET_USER" env BW_SESSION="${BW_SESSION:-}" bw "$@"
  fi
}

bitwarden_status() {
  local status_json
  local parsed

  status_json="$(bw_exec status 2>/dev/null || true)"
  parsed="$(printf '%s' "$status_json" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

  if [[ -z "$parsed" ]]; then
    echo "unknown"
  else
    echo "$parsed"
  fi
}

ensure_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Error: this script is for macOS only."
    exit 1
  fi
}

ensure_smb_client() {
  if ! command -v mount_smbfs >/dev/null 2>&1; then
    echo "Error: mount_smbfs not found. SMB client tools appear unavailable on this macOS install."
    exit 1
  fi
}

ensure_tailscale_installed() {
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "Error: tailscale is not installed. Install and connect Tailscale first."
    exit 1
  fi
}

ensure_tailscale_running() {
  if ! tailscale status --json >/dev/null 2>&1; then
    echo "Error: tailscale is not running or not logged in."
    echo "Start Tailscale and connect before running this script."
    exit 1
  fi
}

resolve_bitwarden_password_from_item() {
  local item_name="$1"
  bw_exec get password "$item_name" 2>/dev/null || true
}

resolve_bitwarden_smb_password() {
  if ! command -v bw >/dev/null 2>&1; then
    return 1
  fi

  local status session password
  status="$(bitwarden_status)"

  if [[ "$status" == "unauthenticated" || "$status" == "unknown" ]]; then
    if [[ ! -t 0 ]]; then
      return 1
    fi

    echo "Bitwarden is not authenticated. Attempting 'bw login'..."
    if [[ "$(id -un)" == "$TARGET_USER" ]]; then
      bw login </dev/tty >/dev/tty 2>&1 || return 1
    else
      sudo -H -u "$TARGET_USER" bw login </dev/tty >/dev/tty 2>&1 || return 1
    fi
    status="$(bitwarden_status)"
  fi

  if [[ "$status" == "locked" ]]; then
    echo "Bitwarden vault is locked. Attempting 'bw unlock'..."
    if [[ -f "$BW_MASTER_PASSWORD_FILE" ]]; then
      local bw_master_password
      bw_master_password="$(<"$BW_MASTER_PASSWORD_FILE")"
      [[ -n "$bw_master_password" ]] || return 1

      if [[ "$(id -un)" == "$TARGET_USER" ]]; then
        export BW_MASTER_PASSWORD="$bw_master_password"
        session="$(bw unlock --passwordenv BW_MASTER_PASSWORD --nointeraction --raw 2>/dev/null || true)"
        unset BW_MASTER_PASSWORD
      else
        session="$(sudo -H -u "$TARGET_USER" env BW_MASTER_PASSWORD="$bw_master_password" bw unlock --passwordenv BW_MASTER_PASSWORD --nointeraction --raw 2>/dev/null || true)"
      fi
    else
      if [[ ! -t 0 ]]; then
        return 1
      fi

      if [[ "$(id -un)" == "$TARGET_USER" ]]; then
        session="$(bw unlock --raw </dev/tty 2>/dev/null || true)"
      else
        session="$(sudo -H -u "$TARGET_USER" bw unlock --raw </dev/tty 2>/dev/null || true)"
      fi
    fi

    session="$(printf '%s' "$session" | tr -d '\r\n')"
    [[ -n "$session" ]] || return 1
    export BW_SESSION="$session"
  fi

  password="$(resolve_bitwarden_password_from_item "$BITWARDEN_ITEM_NAME")"
  if [[ -z "$password" ]]; then
    bw_exec sync >/dev/null 2>&1 || true
    password="$(resolve_bitwarden_password_from_item "$BITWARDEN_ITEM_NAME")"
  fi

  if [[ -n "$password" ]]; then
    SMB_PASSWORD="$password"
    return 0
  fi

  return 1
}

prompt_smb_password_fallback() {
  if [[ ! -t 0 ]]; then
    echo "Error: Could not resolve SMB password from Bitwarden and no interactive terminal is available."
    exit 1
  fi

  local prompt_password
  while true; do
    read -r -s -p "Enter SMB password for user '${TARGET_USER}': " prompt_password </dev/tty
    echo
    if [[ -n "$prompt_password" ]]; then
      SMB_PASSWORD="$prompt_password"
      return 0
    fi
    echo "Password cannot be empty."
  done
}

write_nsmb_conf() {
  SMB_PASSWORD="$(printf '%s' "$SMB_PASSWORD" | tr -d '\r\n')"

  local tmp_file
  tmp_file="$(mktemp)"

  if sudo test -f "$NSMB_CONF_PATH"; then
    sudo cp "$NSMB_CONF_PATH" "$tmp_file"
  fi

  awk -v section="[${SMB_SERVER_IP}:${TARGET_USER}]" '
    BEGIN { in_section=0 }
    {
      if ($0 ~ /^\[/) {
        if ($0 == section) {
          in_section=1
          next
        }
        in_section=0
      }

      if (!in_section) {
        print $0
      }
    }
  ' "$tmp_file" >"${tmp_file}.new"

  {
    cat "${tmp_file}.new"
    [[ -s "${tmp_file}.new" ]] && echo
    echo "[${SMB_SERVER_IP}:${TARGET_USER}]"
    echo "password=${SMB_PASSWORD}"
    echo "port445=no_netbios"
  } >"${tmp_file}.final"

  sudo install -m 600 "${tmp_file}.final" "$NSMB_CONF_PATH"
  rm -f "$tmp_file" "${tmp_file}.new" "${tmp_file}.final"
}

cleanup_existing_storage_mounts() {
  if mount | grep -E " on ${SMB_MOUNT_POINT//\//\/} \(smbfs" >/dev/null 2>&1; then
    echo "Unmounting existing SMB mount at ${SMB_MOUNT_POINT}"
    sudo umount "$SMB_MOUNT_POINT" 2>/dev/null || sudo diskutil unmount force "$SMB_MOUNT_POINT" >/dev/null 2>&1 || true
  fi
}

write_mount_helper_script() {
  sudo tee "$HELPER_SCRIPT_PATH" >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail

MOUNT_POINT="${SMB_MOUNT_POINT}"
SERVER_IP="${SMB_SERVER_IP}"
SHARE_NAME="${SMB_SHARE_NAME}"
TARGET_USER="${TARGET_USER}"

if ! command -v tailscale >/dev/null 2>&1; then
  exit 1
fi

if ! tailscale status --json >/dev/null 2>&1; then
  exit 1
fi

mkdir -p "\$MOUNT_POINT"

if mount | grep -E " on \$MOUNT_POINT \\(smbfs" >/dev/null 2>&1; then
  exit 0
fi

exec mount_smbfs -N "//\$TARGET_USER@\$SERVER_IP/\$SHARE_NAME" "\$MOUNT_POINT"
EOF

  sudo chmod 700 "$HELPER_SCRIPT_PATH"
}

write_launchd_plist() {
  sudo tee "$LAUNCHD_PLIST_PATH" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${HELPER_SCRIPT_PATH}</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>StartInterval</key>
  <integer>20</integer>

  <key>StandardOutPath</key>
  <string>/var/log/storage-smb-mount.log</string>

  <key>StandardErrorPath</key>
  <string>/var/log/storage-smb-mount.err</string>
</dict>
</plist>
EOF

  sudo chmod 644 "$LAUNCHD_PLIST_PATH"
}

enable_and_start_launchd() {
  sudo launchctl bootout system "$LAUNCHD_PLIST_PATH" >/dev/null 2>&1 || true
  sudo launchctl bootstrap system "$LAUNCHD_PLIST_PATH"
  sudo launchctl enable "system/${LAUNCHD_LABEL}" >/dev/null 2>&1 || true
  sudo launchctl kickstart -k "system/${LAUNCHD_LABEL}" >/dev/null 2>&1 || true

  sleep 1

  if mount | grep -E " on ${SMB_MOUNT_POINT//\//\/} \(smbfs" >/dev/null 2>&1; then
    echo "SMB share mounted at ${SMB_MOUNT_POINT}."
  else
    echo "Mount is not up yet. launchd will retry every 20 seconds."
    echo "Check logs with: sudo tail -f /var/log/storage-smb-mount.err"
  fi
}

ensure_macos
ensure_smb_client
ensure_tailscale_installed
ensure_tailscale_running

if ! resolve_bitwarden_smb_password; then
  echo "Bitwarden password resolution failed for '${BITWARDEN_ITEM_NAME}'."
  prompt_smb_password_fallback
fi

cleanup_existing_storage_mounts
sudo mkdir -p "$SMB_MOUNT_POINT"
sudo chown "$TARGET_UID":wheel "$SMB_MOUNT_POINT" 2>/dev/null || true
write_nsmb_conf
write_mount_helper_script
write_launchd_plist
enable_and_start_launchd

echo "Setup complete. SMB share //${SMB_SERVER_IP}/${SMB_SHARE_NAME} is managed by ${LAUNCHD_LABEL}."
