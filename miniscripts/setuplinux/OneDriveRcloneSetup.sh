#!/usr/bin/env bash

set -euo pipefail

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "$TARGET_HOME" ]]; then
  echo "Error: Could not resolve home directory for user '$TARGET_USER'."
  exit 1
fi

TARGET_GROUP="$(id -gn "$TARGET_USER")"

run_as_target_user() {
  if [[ "$(id -un)" == "$TARGET_USER" ]]; then
    "$@"
  else
    sudo -u "$TARGET_USER" "$@"
  fi
}

HOME_DIR="$TARGET_HOME"
RCLONE_CONFIG="$HOME_DIR/.config/rclone/rclone.conf"
ONEDRIVE_DIR="$HOME_DIR/OneDrive"
LOCAL_WALLPAPER_DIR="$HOME_DIR/OneDrive-Local/Media/Wallpapers"
SERVICE_PATH="/etc/systemd/system/rclone-mount.service"
DESIRED_CRON_ENTRIES=(
  "1 * * * * rclone bisync OneDrive:Media/Wallpapers $LOCAL_WALLPAPER_DIR --verbose"
  "1 1 * * 1 rclone bisync OneDrive:Media/Wallpapers $LOCAL_WALLPAPER_DIR --resync --verbose"
)

normalize_crontab() {
  sed 's/[[:space:]]\+$//' | sed '/^[[:space:]]*$/d'
}

echo "Installing rclone..."
sudo apt install -y rclone

echo "Starting rclone config for user '$TARGET_USER'..."
while true; do
  run_as_target_user rclone config --config "$RCLONE_CONFIG" </dev/tty >/dev/tty 2>&1
  if run_as_target_user rclone listremotes --config "$RCLONE_CONFIG" 2>/dev/null | grep -qE '^OneDrive:$'; then
    echo "Found remote 'OneDrive:' in $RCLONE_CONFIG"
    break
  fi

  echo "Remote 'OneDrive:' was not found."
  echo "Press Enter to run rclone config again, or Ctrl+C to exit."
  read -r </dev/tty
done

echo "Ensuring mountpoint exists at $ONEDRIVE_DIR..."
mkdir -p "$ONEDRIVE_DIR"
chown "$TARGET_USER:$TARGET_GROUP" "$ONEDRIVE_DIR"

echo "Creating or updating systemd service at $SERVICE_PATH..."
sudo tee "$SERVICE_PATH" > /dev/null <<EOF
[Unit]
Description=Rclone mount for OneDrive
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/rclone mount OneDrive: $ONEDRIVE_DIR --vfs-cache-mode writes
ExecStop=/bin/fusermount -uz $ONEDRIVE_DIR
Restart=on-failure
User=$TARGET_USER
Group=$TARGET_GROUP

[Install]
WantedBy=default.target
EOF

echo "Enabling and starting rclone-mount.service..."
sudo systemctl daemon-reload
sudo systemctl enable rclone-mount.service
sudo systemctl start rclone-mount.service

echo "Ensuring local wallpaper sync directory exists..."
mkdir -p "$LOCAL_WALLPAPER_DIR"
chown -R "$TARGET_USER:$TARGET_GROUP" "$HOME_DIR/OneDrive-Local"

echo "Running initial one-time bisync resync..."
run_as_target_user rclone bisync OneDrive:Media/Wallpapers "$LOCAL_WALLPAPER_DIR" --resync --verbose

if [[ "$(id -u)" -eq 0 ]]; then
  current_crontab="$(crontab -u "$TARGET_USER" -l 2>/dev/null || true)"
else
  current_crontab="$(crontab -l 2>/dev/null || true)"
fi
desired_crontab="$(printf "%s\n" "${DESIRED_CRON_ENTRIES[@]}")"

if [[ "$(printf "%s\n" "$current_crontab" | normalize_crontab)" == "$(printf "%s\n" "$desired_crontab" | normalize_crontab)" ]]; then
  echo "Crontab already matches desired entries. No changes made."
else
  if [[ "$(id -u)" -eq 0 ]]; then
    printf "%s\n" "${DESIRED_CRON_ENTRIES[@]}" | crontab -u "$TARGET_USER" -
  else
    printf "%s\n" "${DESIRED_CRON_ENTRIES[@]}" | crontab -
  fi
  echo "Crontab updated. Only desired entries are present now."
fi

echo "OneDrive rclone setup complete."