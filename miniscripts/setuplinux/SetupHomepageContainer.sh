#!/usr/bin/env bash

set -euo pipefail

CONTAINER_NAME="portainer"
PORTAINER_VOLUME="portainer_data"
PORTAINER_IMAGE="portainer/portainer-ce:latest"
HTTP_PORT=9000
HTTPS_PORT=9443
AGENT_PORT=8000

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

TARGET_USER="${SUDO_USER:-$USER}"

if groups "$TARGET_USER" | grep -qw docker; then
  echo "User '$TARGET_USER' is already in the docker group."
else
  echo "Adding '$TARGET_USER' to the docker group..."
  sudo usermod -aG docker "$TARGET_USER"
  echo "Note: Log out and back in (or run 'newgrp docker') for group changes to take effect in new terminals."
fi

# ─── Portainer Volume ─────────────────────────────────────────────────────────

if sudo docker volume inspect "$PORTAINER_VOLUME" >/dev/null 2>&1; then
  echo "Docker volume '$PORTAINER_VOLUME' already exists."
else
  echo "Creating Docker volume '$PORTAINER_VOLUME'..."
  sudo docker volume create "$PORTAINER_VOLUME"
fi

# ─── Portainer Container ──────────────────────────────────────────────────────

# Always remove and recreate the container so config changes (e.g. password
# policy) take effect on re-runs. Data is safe because it lives in the volume.
if sudo docker ps -a --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "Removing existing Portainer container to apply current configuration..."
  sudo docker rm -f "$CONTAINER_NAME"
fi

echo "Creating and starting Portainer container..."
sudo docker run -d \
  --name "$CONTAINER_NAME" \
  --restart always \
  -p "${AGENT_PORT}:8000" \
  -p "${HTTPS_PORT}:9443" \
  -p "${HTTP_PORT}:9000" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${PORTAINER_VOLUME}:/data" \
  "$PORTAINER_IMAGE"

# ─── Firewall ─────────────────────────────────────────────────────────────────

if command -v ufw >/dev/null 2>&1 && sudo ufw status | grep -q "Status: active"; then
  echo "UFW is active — opening Portainer ports..."
  sudo ufw allow "${HTTP_PORT}/tcp" comment "Portainer HTTP"
  sudo ufw allow "${HTTPS_PORT}/tcp" comment "Portainer HTTPS"
  sudo ufw allow "${AGENT_PORT}/tcp" comment "Portainer Agent"
  echo "UFW rules added for ports ${HTTP_PORT}, ${HTTPS_PORT}, and ${AGENT_PORT}."
else
  echo "UFW is not active — skipping firewall rules."
fi

# ─── Health Check ─────────────────────────────────────────────────────────────

echo "Waiting for Portainer to become ready..."
HEALTH_TIMEOUT=30
HEALTH_INTERVAL=2
elapsed=0
until curl -fsSk "https://localhost:${HTTPS_PORT}/api/status" >/dev/null 2>&1; do
  if [[ $elapsed -ge $HEALTH_TIMEOUT ]]; then
    echo ""
    echo "ERROR: Portainer did not become ready within ${HEALTH_TIMEOUT} seconds."
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
echo "Portainer is ready."

# ─── Done ─────────────────────────────────────────────────────────────────────

LOCAL_IP="$(ip route get 1.1.1.1 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
if [[ -z "$LOCAL_IP" ]]; then
  LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

echo ""
echo "Portainer is up and running."
echo "  HTTPS (recommended): https://${LOCAL_IP}:${HTTPS_PORT}"
echo "  HTTP:                http://${LOCAL_IP}:${HTTP_PORT}"
echo ""
echo "Access it from any device on your network using the URLs above."
echo "On first visit, create your admin account within 5 minutes."
echo ""
echo "SetupHomepageContainer complete."
