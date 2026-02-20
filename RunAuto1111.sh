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
# Install if not present, then verify the GPU is actually reachable.
# libnvidia-ml.so.1 errors mean ldconfig hasn't been run after install — always
# run it to ensure the NVIDIA libraries are in the dynamic linker cache.

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
  sudo ldconfig
  sudo systemctl restart docker
  echo "NVIDIA Container Toolkit installed."
else
  echo "NVIDIA Container Toolkit is already configured."
  # Always refresh the library cache in case the toolkit was installed without it
  sudo ldconfig
fi

# Verify the GPU is reachable inside Docker before attempting to start A1111
echo "Verifying GPU access in Docker..."
if ! sudo docker run --rm --gpus all nvidia/cuda:12.3.1-base-ubuntu22.04 nvidia-smi \
    >/dev/null 2>&1; then
  echo ""
  echo "ERROR: Docker cannot access the NVIDIA GPU."
  echo "Possible causes:"
  echo "  1. NVIDIA driver is not installed — run: sudo ubuntu-drivers install"
  echo "  2. Driver version mismatch — reboot after driver install and retry"
  echo "  3. Secure Boot may be blocking the kernel module — check: dmesg | grep nvidia"
  exit 1
fi
echo "GPU access confirmed."

# ─── Data Directories ─────────────────────────────────────────────────────────

mkdir -p \
  "${DATA_DIR}/models/Stable-diffusion" \
  "${DATA_DIR}/models/VAE" \
  "${DATA_DIR}/models/Lora" \
  "${DATA_DIR}/outputs" \
  "${DATA_DIR}/extensions"

echo "Data directory: ${DATA_DIR}"

# ─── Download Model ───────────────────────────────────────────────────────────
# DreamShaper 8 — no login required, no content filter, high quality general
# purpose model. Publicly hosted on HuggingFace (Lykon/DreamShaper).

SD_MODEL_FILE="${DATA_DIR}/models/Stable-diffusion/dreamshaper_8.safetensors"
SD_MODEL_URL="https://huggingface.co/Lykon/DreamShaper/resolve/main/DreamShaper_8_pruned.safetensors"

if [[ -f "$SD_MODEL_FILE" ]]; then
  echo "Model already present: $(basename "$SD_MODEL_FILE") — skipping download."
else
  echo "Downloading DreamShaper 8 model (~2 GB, no login required)..."
  wget --show-progress -q -c "$SD_MODEL_URL" -O "$SD_MODEL_FILE"
  echo "Model downloaded: $SD_MODEL_FILE"
fi

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
  --listen --xformers --api --no-half --skip-torch-cuda-test --no-download-sd-model

# ─── Wait for ready ───────────────────────────────────────────────────────────

ACCESS_IP="$(tailscale ip -4 2>/dev/null || true)"
if [[ -z "$ACCESS_IP" ]]; then
  ACCESS_IP="$(ip route get 1.1.1.1 2>/dev/null \
    | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
fi
if [[ -z "$ACCESS_IP" ]]; then
  ACCESS_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

echo ""
echo "Waiting for auto1111 to finish loading (this takes several minutes on first run)..."
echo "Showing container logs — ready when you see 'Running on local URL':"
echo "──────────────────────────────────────────────────────────────────"

READY=0
TIMEOUT=600  # 10 minutes
ELAPSED=0
INTERVAL=5

while [[ $ELAPSED -lt $TIMEOUT ]]; do
  STATUS="$(sudo docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")"
  if [[ "$STATUS" == "exited" ]]; then
    echo ""
    echo "ERROR: auto1111 container exited unexpectedly."
    echo "Container logs:"
    sudo docker logs --tail 50 "$CONTAINER_NAME" || true
    exit 1
  fi

  if curl -fsS "http://localhost:${HTTP_PORT}" >/dev/null 2>&1; then
    READY=1
    break
  fi

  LAST_LOG="$(sudo docker logs --tail 1 "$CONTAINER_NAME" 2>/dev/null || true)"
  if [[ -n "$LAST_LOG" ]]; then
    printf "\r%-120s" "$LAST_LOG"
  fi

  sleep "$INTERVAL"
  ELAPSED=$(( ELAPSED + INTERVAL ))
done

echo ""
echo "──────────────────────────────────────────────────────────────────"

if [[ "$READY" -eq 0 ]]; then
  echo "WARNING: auto1111 did not respond within ${TIMEOUT}s."
  echo "Check progress with:  sudo docker logs -f ${CONTAINER_NAME}"
  echo ""
fi

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "auto1111 is ready."
echo "  http://${ACCESS_IP}:${HTTP_PORT}"
echo ""
echo "Model loaded: DreamShaper 8 (no content filter)"
echo ""
echo "Drop additional .safetensors files into:"
echo "  ${DATA_DIR}/models/Stable-diffusion/"
echo "Then click the refresh button next to the model dropdown in the UI."
echo ""
echo "To tear everything down and free disk space:"
echo "  $(basename "$0") -n"
