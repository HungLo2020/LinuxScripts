#!/usr/bin/env bash

set -euo pipefail

CONTAINER_NAME="homepage"
HOMEPAGE_IMAGE="ghcr.io/gethomepage/homepage:latest"
HTTP_PORT=3000
REFRESH_PORT=9002

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REFRESH_SCRIPT="$REPO_ROOT/miniscripts/notautorun/RefreshContainers.sh"

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
  echo "Error: Could not determine home directory for user '$TARGET_USER'."
  exit 1
fi

CONFIG_DIR="$TARGET_HOME/.config/homepage"

# ─── Tailscale Check ──────────────────────────────────────────────────────────

if ! command -v tailscale >/dev/null 2>&1; then
  echo "ERROR: Tailscale is not installed."
  echo "Please run RDSetup.sh to install and configure Tailscale before running this script."
  exit 1
fi

TAILSCALE_IP="$(tailscale ip -4 2>/dev/null || true)"
if [[ -z "$TAILSCALE_IP" ]]; then
  echo "ERROR: Tailscale is installed but not connected."
  echo "Run 'sudo tailscale up' and log in before running this script."
  exit 1
fi

echo "Tailscale is connected. Using Tailscale IP: ${TAILSCALE_IP}"

# ─── Docker Installation ──────────────────────────────────────────────────────

if command -v docker >/dev/null 2>&1; then
  echo "Docker is already installed: $(docker --version)"
else
  echo "Installing Docker CE..."
  sudo apt update
  sudo apt install -y ca-certificates curl gnupg

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  echo "Docker installed: $(docker --version)"
fi

# ─── Docker Service ───────────────────────────────────────────────────────────

if ! sudo systemctl is-active --quiet docker; then
  echo "Enabling and starting Docker service..."
  sudo systemctl enable --now docker
else
  echo "Docker service is already running."
fi

# ─── Docker Group ─────────────────────────────────────────────────────────────

if groups "$TARGET_USER" | grep -qw docker; then
  echo "User '$TARGET_USER' is already in the docker group."
else
  echo "Adding '$TARGET_USER' to the docker group..."
  sudo usermod -aG docker "$TARGET_USER"
  echo "Note: Log out and back in (or run 'newgrp docker') for group changes to take effect in new terminals."
fi

# ─── Config Directory ─────────────────────────────────────────────────────────

echo "Ensuring Homepage config directory exists at $CONFIG_DIR..."
mkdir -p "$CONFIG_DIR"
sudo chown -R "$TARGET_USER":"$TARGET_USER" "$CONFIG_DIR"

# Write starter config files only if they do not already exist,
# so re-running this script never overwrites customisations.

write_if_missing() {
  local filepath="$1"
  local content="$2"
  if [[ -f "$filepath" ]]; then
    echo "Config already exists, skipping: $(basename "$filepath")"
  else
    echo "$content" > "$filepath"
    chown "$TARGET_USER":"$TARGET_USER" "$filepath"
    echo "Created starter config: $(basename "$filepath")"
  fi
}

write_if_missing "$CONFIG_DIR/settings.yaml" \
'title: My Server
theme: dark
color: slate
headerStyle: boxed
layout:
  Media:
    style: row
    columns: 4
  Links:
    style: row
    columns: 4'

# services.yaml is always overwritten. Docker-labelled containers (Portainer,
# Homepage) are auto-discovered via the Docker socket. The Refresh Containers
# tile is added here because ttyd runs on the host, not in a container.
cat > "$CONFIG_DIR/services.yaml" << EOF
- Management:
    - Refresh Containers:
        icon: bash.png
        href: http://${TAILSCALE_IP}:${REFRESH_PORT}
        description: Update scripts and refresh all containers
EOF
chown "$TARGET_USER":"$TARGET_USER" "$CONFIG_DIR/services.yaml"
echo "Written services.yaml with Refresh Containers tile."

write_if_missing "$CONFIG_DIR/widgets.yaml" \
'- resources:
    cpu: true
    memory: true
    disk: /

- datetime:
    text_size: xl
    format:
      timeStyle: short
      dateStyle: short'

write_if_missing "$CONFIG_DIR/bookmarks.yaml" \
'- Developer:
    - GitHub:
        - abbr: GH
          href: https://github.com

- Media:
    - YouTube:
        - abbr: YT
          href: https://youtube.com'

write_if_missing "$CONFIG_DIR/docker.yaml" \
'my-server:
  socket: /var/run/docker.sock'

# ─── Homepage Container ───────────────────────────────────────────────────────

# Always remove and recreate the container so config/port changes take effect
# on re-runs. Config is safe because it lives in the host config directory.
if sudo docker ps -a --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "Removing existing Homepage container to apply current configuration..."
  sudo docker rm -f "$CONTAINER_NAME"
fi

echo "Creating and starting Homepage container..."
sudo docker run -d \
  --name "$CONTAINER_NAME" \
  --restart always \
  -p "${HTTP_PORT}:3000" \
  -e "HOMEPAGE_ALLOWED_HOSTS=*" \
  -v "${CONFIG_DIR}:/app/config" \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  --label "homepage.name=Homepage" \
  --label "homepage.icon=homepage.png" \
  --label "homepage.href=http://${TAILSCALE_IP}:${HTTP_PORT}" \
  --label "homepage.description=This Dashboard" \
  --label "homepage.group=Management" \
  "$HOMEPAGE_IMAGE"

# ─── Refresh Terminal (ttyd) ──────────────────────────────────────────────────

if ! command -v ttyd >/dev/null 2>&1; then
  echo "Installing ttyd (web terminal for Refresh Containers tile)..."
  sudo apt install -y ttyd
else
  echo "ttyd is already installed."
fi

if [[ ! -f "$REFRESH_SCRIPT" ]]; then
  echo "ERROR: RefreshContainers.sh not found at: $REFRESH_SCRIPT"
  exit 1
fi

REFRESH_SERVICE_PATH="/etc/systemd/system/homepage-refresh.service"
echo "Writing homepage-refresh systemd service..."
sudo tee "$REFRESH_SERVICE_PATH" > /dev/null << EOF
[Unit]
Description=Homepage Refresh Containers terminal (ttyd)
After=network.target

[Service]
ExecStart=/usr/bin/ttyd -p ${REFRESH_PORT} -t fontSize=14 bash -c 'sudo bash ${REFRESH_SCRIPT}; echo ""; echo "Refresh complete. You may close this tab."; sleep 60'
Restart=always
User=${TARGET_USER}

[Install]
WantedBy=multi-user.target
EOF

echo "Enabling and restarting homepage-refresh service..."
sudo systemctl daemon-reload
sudo systemctl enable --now homepage-refresh.service
sudo systemctl restart homepage-refresh.service

# ─── Firewall ─────────────────────────────────────────────────────────────────

if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q "Status: active"; then
  echo "UFW is active — opening Homepage and Refresh ports..."
  sudo ufw allow "${HTTP_PORT}/tcp" comment "Homepage Dashboard" || true
  sudo ufw allow "${REFRESH_PORT}/tcp" comment "Homepage Refresh Terminal" || true
  echo "UFW rules added for ports ${HTTP_PORT} and ${REFRESH_PORT}."
else
  echo "UFW is not active — skipping firewall rules."
fi

# ─── Health Check ─────────────────────────────────────────────────────────────

echo "Waiting for Homepage to become ready..."
HEALTH_TIMEOUT=60
HEALTH_INTERVAL=2
elapsed=0
until curl -fsS "http://localhost:${HTTP_PORT}" >/dev/null 2>&1; do
  if [[ $elapsed -ge $HEALTH_TIMEOUT ]]; then
    echo ""
    echo "ERROR: Homepage did not become ready within ${HEALTH_TIMEOUT} seconds."
    echo "Container status:"
    sudo docker inspect --format '{{.State.Status}} (exit code: {{.State.ExitCode}})' "$CONTAINER_NAME" || true
    echo ""
    echo "Recent container logs:"
    sudo docker logs --tail 30 "$CONTAINER_NAME" || true
    exit 1
  fi
  sleep "$HEALTH_INTERVAL"
  elapsed=$(( elapsed + HEALTH_INTERVAL ))
done
echo "Homepage is ready."

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "Homepage dashboard is up and running."
echo "  Dashboard:         http://${TAILSCALE_IP}:${HTTP_PORT}"
echo "  Refresh terminal:  http://${TAILSCALE_IP}:${REFRESH_PORT}"
echo ""
echo "Accessible from anywhere on your Tailscale network."
echo ""
echo "The 'Refresh Containers' tile on the dashboard opens a browser terminal."
echo "Click it to pull the latest scripts and recreate all containers."
echo ""
echo "To add a new container to the dashboard, add these labels to its docker run command:"
echo "  --label homepage.name=\"My App\""
echo "  --label homepage.icon=\"myapp.png\""
echo "  --label homepage.href=\"http://${TAILSCALE_IP}:<port>\""
echo "  --label homepage.description=\"My description\""
echo "  --label homepage.group=\"My Group\""
echo ""
echo "SetupDashboardContainer complete."
