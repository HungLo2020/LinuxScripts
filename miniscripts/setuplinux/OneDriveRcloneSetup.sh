#!/usr/bin/env bash

set -euo pipefail

CURRENT_USER="$(id -un)"
CURRENT_GROUP="$(id -gn)"
HOME_DIR="$HOME"
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

echo "Starting rclone config..."
while true; do
  rclone config --config "$RCLONE_CONFIG" </dev/tty >/dev/tty 2>&1
  if rclone listremotes --config "$RCLONE_CONFIG" 2>/dev/null | grep -qE '^OneDrive:$'; then
    echo "Found remote 'OneDrive:' in $RCLONE_CONFIG"
    break
  fi

  echo "Remote 'OneDrive:' was not found."
  echo "Press Enter to run rclone config again, or Ctrl+C to exit."
  read -r </dev/tty
done

echo "Ensuring mountpoint exists at $ONEDRIVE_DIR..."
mkdir -p "$ONEDRIVE_DIR"

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
User=$CURRENT_USER
Group=$CURRENT_GROUP

[Install]
WantedBy=default.target
EOF

echo "Enabling and starting rclone-mount.service..."
sudo systemctl daemon-reload
sudo systemctl enable rclone-mount.service
sudo systemctl start rclone-mount.service

echo "Ensuring local wallpaper sync directory exists..."
mkdir -p "$LOCAL_WALLPAPER_DIR"

echo "Running initial one-time bisync resync..."
rclone bisync OneDrive:Media/Wallpapers "$LOCAL_WALLPAPER_DIR" --resync --verbose

current_crontab="$(crontab -l 2>/dev/null || true)"
desired_crontab="$(printf "%s\n" "${DESIRED_CRON_ENTRIES[@]}")"

if [[ "$(printf "%s\n" "$current_crontab" | normalize_crontab)" == "$(printf "%s\n" "$desired_crontab" | normalize_crontab)" ]]; then
  echo "Crontab already matches desired entries. No changes made."
else
  printf "%s\n" "${DESIRED_CRON_ENTRIES[@]}" | crontab -
  echo "Crontab updated. Only desired entries are present now."
fi

echo "OneDrive rclone setup complete."