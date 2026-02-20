#!/usr/bin/env bash

set -euo pipefail

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
  echo "Error: Could not determine home directory for user '$TARGET_USER'."
  exit 1
fi

COMPOSE_DIR="$TARGET_HOME/.local/share/docker/ollama"
COMPOSE_FILE="$COMPOSE_DIR/compose.yml"
OLLAMA_MODEL="dolphin-llama3:8b"   # uncensored Llama 3 fine-tune; no built-in content restrictions

# ---------------------------------------------------------------
# Docker CE
# ---------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  echo "Docker is already installed: $(docker --version)"
else
  echo "Installing Docker CE..."
  sudo apt install -y ca-certificates curl gnupg

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  sudo apt update
  sudo apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  echo "Docker CE installed."
fi

# ---------------------------------------------------------------
# Add user to docker group
# ---------------------------------------------------------------
if id -nG "$TARGET_USER" | grep -qw docker; then
  echo "User '$TARGET_USER' is already in the docker group."
else
  echo "Adding '$TARGET_USER' to the docker group..."
  sudo usermod -aG docker "$TARGET_USER"
  echo "NOTE: A log out and back in (or 'newgrp docker') is required for the group change to take effect."
fi

# ---------------------------------------------------------------
# NVIDIA Container Toolkit
# ---------------------------------------------------------------
if dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
  echo "nvidia-container-toolkit is already installed."
else
  echo "Installing NVIDIA Container Toolkit..."

  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

  sudo apt update
  sudo apt install -y nvidia-container-toolkit

  echo "Configuring Docker to use the NVIDIA runtime..."
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker

  echo "NVIDIA Container Toolkit installed."
fi

# ---------------------------------------------------------------
# Docker Compose file for Ollama + Open WebUI
# ---------------------------------------------------------------
echo "Writing Docker Compose config to $COMPOSE_FILE..."
mkdir -p "$COMPOSE_DIR"

cat > "$COMPOSE_FILE" <<'EOF'
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    runtime: nvidia
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
    volumes:
      - ollama:/root/.ollama
    ports:
      - "11434:11434"
    restart: unless-stopped

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    depends_on:
      - ollama
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
    volumes:
      - open-webui:/app/backend/data
    ports:
      - "3000:8080"
    restart: unless-stopped

volumes:
  ollama:
  open-webui:
EOF

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R "$TARGET_USER:$(id -gn "$TARGET_USER")" "$COMPOSE_DIR"
fi

# ---------------------------------------------------------------
# Start containers
# ---------------------------------------------------------------
echo "Starting Ollama and Open WebUI containers..."
echo "  (Docker will pull the Ollama and Open WebUI images if not already cached — this may take several minutes)"
sudo docker compose -f "$COMPOSE_FILE" up -d --remove-orphans

# ---------------------------------------------------------------
# Pull Ollama model
# ---------------------------------------------------------------
echo "Waiting for Ollama container to be ready..."
for i in {1..60}; do
  if sudo docker exec ollama ollama list >/dev/null 2>&1; then
    break
  fi
  echo "  Waiting... ($i/60)"
  sleep 5
done

if ! sudo docker exec ollama ollama list >/dev/null 2>&1; then
  echo "Error: Ollama container did not become ready in time."
  exit 1
fi

echo "Pulling $OLLAMA_MODEL (this may take a while — the model is ~4.7 GB)..."
sudo docker exec ollama ollama pull "$OLLAMA_MODEL"

echo ""
echo "Setup complete."
echo "  Open WebUI: http://localhost:3000"
echo "  Ollama API: http://localhost:11434"
echo ""
echo "On first launch, create an admin account at http://localhost:3000"
echo "The $OLLAMA_MODEL model is ready to use."
