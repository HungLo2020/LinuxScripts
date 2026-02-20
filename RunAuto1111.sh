#!/usr/bin/env bash

set -euo pipefail

CONTAINER_NAME="auto1111"
IMAGE="universonic/stable-diffusion-webui:latest"
DATA_DIR="${HOME}/.local/share/auto1111"
HTTP_PORT=7860

# ─── Teardown (-n) ────────────────────────────────────────────────────────────

if [[ "${1:-}" == "-n" ]]; then
  echo "Stopping and removing auto1111..."
  sudo docker rm -f "$CONTAINER_NAME" 2>/dev/null \
    && echo "Container removed." \
    || echo "No running container to remove."
  sudo docker rmi "$IMAGE" 2>/dev/null \
    && echo "Image removed." \
    || echo "No image to remove."
  if [[ -d "$DATA_DIR" ]]; then
    read -r -p "Delete all auto1111 data (models, outputs, extensions) at ${DATA_DIR}? [y/N] " confirm
    if [[ "${confirm,,}" == "y" ]]; then
      rm -rf "$DATA_DIR"
      echo "Data directory removed: $DATA_DIR"
    else
      echo "Data directory kept: $DATA_DIR"
    fi
  else
    echo "No data directory to remove."
  fi
  echo "auto1111 teardown complete."
  exit 0
fi

# ─── Docker Check ─────────────────────────────────────────────────────────────

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is not installed."
  echo "Run one of the container setup scripts first, or install Docker CE manually."
  exit 1
fi

# ─── NVIDIA Container Toolkit ─────────────────────────────────────────────────

if ! sudo docker info 2>/dev/null | grep -q '"nvidia"'; then
  echo "NVIDIA Container Toolkit not detected — installing..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt update
  sudo apt install -y nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
  echo "NVIDIA Container Toolkit installed."
else
  echo "NVIDIA Container Toolkit is already configured."
fi

# ─── Data Directories ─────────────────────────────────────────────────────────

mkdir -p \
  "${DATA_DIR}/models/Stable-diffusion" \
  "${DATA_DIR}/models/VAE" \
  "${DATA_DIR}/models/Lora" \
  "${DATA_DIR}/outputs" \
  "${DATA_DIR}/extensions"

echo "Data directory: ${DATA_DIR}"

# ─── Container ────────────────────────────────────────────────────────────────

if sudo docker ps -a --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' \
    | grep -q "^${CONTAINER_NAME}$"; then
  echo "Removing existing auto1111 container..."
  sudo docker rm -f "$CONTAINER_NAME"
fi

echo "Pulling latest auto1111 image..."
sudo docker pull "$IMAGE"

echo "Starting auto1111..."
sudo docker run -d \
  --name "$CONTAINER_NAME" \
  --gpus all \
  --restart unless-stopped \
  -p "${HTTP_PORT}:7860" \
  -v "${DATA_DIR}/models:/stable-diffusion-webui/models" \
  -v "${DATA_DIR}/outputs:/stable-diffusion-webui/outputs" \
  -v "${DATA_DIR}/extensions:/stable-diffusion-webui/extensions" \
  "$IMAGE" \
  --listen --xformers --api --no-half

# ─── Done ─────────────────────────────────────────────────────────────────────

ACCESS_IP="$(tailscale ip -4 2>/dev/null || true)"
if [[ -z "$ACCESS_IP" ]]; then
  ACCESS_IP="$(ip route get 1.1.1.1 2>/dev/null \
    | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
fi
if [[ -z "$ACCESS_IP" ]]; then
  ACCESS_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

echo ""
echo "auto1111 is starting up."
echo "  http://${ACCESS_IP}:${HTTP_PORT}"
echo ""
echo "First startup takes several minutes — models are being downloaded."
echo "Watch progress with:  sudo docker logs -f ${CONTAINER_NAME}"
echo ""
echo "Drop .safetensors model files into:"
echo "  ${DATA_DIR}/models/Stable-diffusion/"
echo ""
echo "To tear everything down and free disk space:"
echo "  $(basename "$0") -n"
