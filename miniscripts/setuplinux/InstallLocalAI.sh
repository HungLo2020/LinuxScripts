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
SD_MODELS_DIR="$COMPOSE_DIR/sd-models"  # host-mounted dir for Stable Diffusion checkpoints
# Stable Diffusion 2.1 — publicly accessible on Hugging Face without authentication
SD_MODEL_FILE="v2-1_768-ema-pruned.safetensors"
SD_MODEL_URL="https://huggingface.co/stabilityai/stable-diffusion-2-1/resolve/main/v2-1_768-ema-pruned.safetensors"

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
# Docker Compose file for Ollama + AUTOMATIC1111 + Open WebUI
# ---------------------------------------------------------------
echo "Writing Docker Compose config to $COMPOSE_FILE..."
mkdir -p "$COMPOSE_DIR"
mkdir -p "$SD_MODELS_DIR"

# ---------------------------------------------------------------
# Download Stable Diffusion model
# ---------------------------------------------------------------
if [[ -f "$SD_MODELS_DIR/$SD_MODEL_FILE" ]]; then
  echo "Stable Diffusion model already present: $SD_MODEL_FILE"
else
  echo "Downloading Stable Diffusion model ($SD_MODEL_FILE) — this may take several minutes (~5.2 GB)..."
  curl -L --progress-bar \
    -o "$SD_MODELS_DIR/$SD_MODEL_FILE.tmp" \
    "$SD_MODEL_URL" \
    || { rm -f "$SD_MODELS_DIR/$SD_MODEL_FILE.tmp"; echo "Error: Failed to download Stable Diffusion model."; exit 1; }
  mv "$SD_MODELS_DIR/$SD_MODEL_FILE.tmp" "$SD_MODELS_DIR/$SD_MODEL_FILE"
  echo "Stable Diffusion model downloaded."
fi

# AUTOMATIC1111 config: disable the built-in NSFW safety filter so the API
# returns images as-is without blacking out flagged content.  This is an
# intentional, user-requested choice for a private, local-only deployment.
cat > "$COMPOSE_DIR/sd-config.json" <<'EOF'
{
  "filter_nsfw": false
}
EOF

# Use a non-quoted heredoc so $SD_MODELS_DIR is expanded to an absolute path,
# avoiding any ambiguity about the working directory at docker-compose runtime.
cat > "$COMPOSE_FILE" <<EOF
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

  automatic1111:
    image: ghcr.io/jim60105/stable-diffusion-webui:latest
    container_name: automatic1111
    runtime: nvidia
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - CLI_ARGS=--api --disable-safe-unpickle
    volumes:
      - $COMPOSE_DIR/sd-config.json:/data/config.json:ro
      - $SD_MODELS_DIR:/data/models/Stable-diffusion
      - sd-outputs:/data/outputs
    ports:
      - "7860:7860"
    restart: unless-stopped

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    depends_on:
      - ollama
      - automatic1111
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - ENABLE_IMAGE_GENERATION=true
      - AUTOMATIC1111_BASE_URL=http://automatic1111:7860
    volumes:
      - open-webui:/app/backend/data
    ports:
      - "3000:8080"
    restart: unless-stopped

volumes:
  ollama:
  open-webui:
  sd-outputs:
EOF

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R "$TARGET_USER:$(id -gn "$TARGET_USER")" "$COMPOSE_DIR"
fi

# ---------------------------------------------------------------
# Start containers
# ---------------------------------------------------------------
echo "Starting Ollama, AUTOMATIC1111, and Open WebUI containers..."
echo "  (Docker will pull images if not already cached — this may take several minutes)"
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
echo "  Open WebUI:    http://localhost:3000"
echo "  AUTOMATIC1111: http://localhost:7860"
echo "  Ollama API:    http://localhost:11434"
echo ""
echo "On first launch, create an admin account at http://localhost:3000"
echo "The $OLLAMA_MODEL model is ready for text generation."
echo ""
echo "For image generation, the $SD_MODEL_FILE model has been pre-downloaded and is ready to use."
echo "Additional Stable Diffusion model files (.safetensors or .ckpt) can be placed in:"
echo "  $SD_MODELS_DIR"
echo "Then restart the image generator: sudo docker compose -f $COMPOSE_FILE restart automatic1111"
echo ""
echo "Image generation is pre-configured in Open WebUI (Settings > Images)."
echo "NSFW filtering is disabled — the image generator will produce unfiltered output."
