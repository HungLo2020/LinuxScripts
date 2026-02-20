#!/usr/bin/env bash
# =============================================================================
# run-automatic1111.sh
#
# Self-contained script to install and run AUTOMATIC1111 Stable Diffusion
# WebUI as a Docker container with NO content filter.
#
# Usage:
#   ./run-automatic1111.sh          Install (if needed) and start the UI
#   ./run-automatic1111.sh -n       Stop the container and delete all files
#
# What this script does:
#   - Installs Docker if it is not already present
#   - Downloads DreamShaper 8 (public model, no login required)
#   - Builds a Docker image containing AUTOMATIC1111 from the official source
#   - Runs the container with the safety / NSFW checker disabled
#   - Passes GPU through to the container when an NVIDIA GPU is detected
#   - Caches the Python venv on the host so subsequent starts are fast
#   - Is idempotent: safe to run any number of times
#
# SECURITY NOTICE:
#   --disable-safe-unpickle  Disables pickle safety checks so that all model
#                            formats can be loaded.  Only load model files from
#                            sources you trust.
#   --allow-code             Permits arbitrary Python execution inside the
#                            prompt pipeline.  Do NOT expose port 7860 to an
#                            untrusted network when this flag is active.
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
CONTAINER_NAME="automatic1111"
IMAGE_NAME="automatic1111-webui"
DATA_DIR="${HOME}/.automatic1111"
PORT=7860

# DreamShaper 8 — publicly accessible on Hugging Face, no account required.
MODEL_FILENAME="DreamShaper_8_pruned.safetensors"
MODEL_URL="https://huggingface.co/Lykon/dreamshaper-8/resolve/main/${MODEL_FILENAME}"

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Wrapper so we can transparently switch to "sudo docker" when the current
# user is not yet in the docker group (e.g. right after installation).
DOCKER_USE_SUDO="false"
docker_exec() {
    if [[ "${DOCKER_USE_SUDO}" == "true" ]]; then
        sudo docker "$@"
    else
        docker "$@"
    fi
}

# ── -n flag: stop container and delete everything ─────────────────────────────
if [[ "${1:-}" == "-n" ]]; then
    log "=== Shutting down AUTOMATIC1111 and removing its files ==="

    # Determine whether sudo is needed before we can talk to Docker.
    if ! docker info &>/dev/null; then
        if sudo docker info &>/dev/null; then
            DOCKER_USE_SUDO="true"
        else
            log "Warning: cannot reach Docker daemon; skipping container/image removal."
        fi
    fi

    if docker_exec ps -q --filter "name=^/${CONTAINER_NAME}$" 2>/dev/null | grep -q .; then
        log "Stopping container..."
        docker_exec stop "${CONTAINER_NAME}"
    else
        log "Container is not running."
    fi

    if docker_exec ps -aq --filter "name=^/${CONTAINER_NAME}$" 2>/dev/null | grep -q .; then
        log "Removing container..."
        docker_exec rm "${CONTAINER_NAME}"
    else
        log "Container does not exist."
    fi

    if docker_exec images -q "${IMAGE_NAME}" 2>/dev/null | grep -q .; then
        log "Removing Docker image..."
        docker_exec rmi "${IMAGE_NAME}"
    else
        log "Docker image does not exist."
    fi

    if [[ -d "${DATA_DIR}" ]]; then
        log "Removing data directory: ${DATA_DIR}"
        rm -rf "${DATA_DIR}"
    else
        log "Data directory does not exist."
    fi

    log "=== Cleanup complete ==="
    exit 0
fi

# ── Install Docker if not present ─────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log "Docker not found. Installing via the official get.docker.com script..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "${USER}" || true
    log "Docker installed."
fi

# Resolve whether we need sudo to run docker commands.
if ! docker info &>/dev/null; then
    if sudo docker info &>/dev/null; then
        DOCKER_USE_SUDO="true"
        log "Using 'sudo docker' for this session (user not yet in docker group)."
    else
        log "Error: cannot connect to the Docker daemon. Is Docker running?"
        exit 1
    fi
fi

# ── Create persistent data directories ───────────────────────────────────────
mkdir -p \
    "${DATA_DIR}/models/Stable-diffusion" \
    "${DATA_DIR}/outputs" \
    "${DATA_DIR}/venv" \
    "${DATA_DIR}/extensions"

# ── Download model (no login required) ───────────────────────────────────────
MODEL_PATH="${DATA_DIR}/models/Stable-diffusion/${MODEL_FILENAME}"

if [[ ! -f "${MODEL_PATH}" ]]; then
    log "Downloading model: ${MODEL_FILENAME}"
    log "This will take several minutes depending on your connection (file is ~2 GB)."
    PARTIAL="${MODEL_PATH}.partial"
    if command -v wget &>/dev/null; then
        wget -c --progress=bar:force:noscroll -O "${PARTIAL}" "${MODEL_URL}"
    else
        curl -L --progress-bar -C - -o "${PARTIAL}" "${MODEL_URL}"
    fi
    mv "${PARTIAL}" "${MODEL_PATH}"
    log "Model downloaded: ${MODEL_FILENAME}"
else
    log "Model already present: ${MODEL_FILENAME}"
fi

# ── Build Docker image (once; image is cached for subsequent runs) ─────────────
if ! docker_exec images -q "${IMAGE_NAME}" 2>/dev/null | grep -q .; then
    log "Building Docker image — this is a one-time step that may take 10-20 minutes."

    BUILD_CTX=$(mktemp -d)
    # shellcheck disable=SC2064
    trap 'rm -rf "${BUILD_CTX}"' EXIT

    cat > "${BUILD_CTX}/Dockerfile" << 'DOCKERFILE'
FROM python:3.10.14-slim-bullseye

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        wget \
        curl \
        libgl1 \
        libglib2.0-0 \
        libsm6 \
        libxrender1 \
        libxext6 \
        libgomp1 \
        ffmpeg \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth=1 https://github.com/AUTOMATIC1111/stable-diffusion-webui /app

WORKDIR /app

RUN mkdir -p \
    /app/models/Stable-diffusion \
    /app/models/VAE \
    /app/outputs \
    /app/extensions \
    /app/venv

EXPOSE 7860
DOCKERFILE

    docker_exec build -t "${IMAGE_NAME}" "${BUILD_CTX}"
    log "Docker image built successfully."
else
    log "Docker image already exists: ${IMAGE_NAME}"
fi

# ── Remove any existing (stopped) container so we start clean ─────────────────
if docker_exec ps -aq --filter "name=^/${CONTAINER_NAME}$" 2>/dev/null | grep -q .; then
    log "Removing leftover container..."
    docker_exec stop "${CONTAINER_NAME}" 2>/dev/null || true
    docker_exec rm "${CONTAINER_NAME}"
fi

# ── GPU detection ─────────────────────────────────────────────────────────────
USE_GPU="false"
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    if docker_exec info 2>/dev/null | grep -qi "nvidia\|gpu runtime"; then
        USE_GPU="true"
        log "NVIDIA GPU detected — enabling GPU passthrough."
    else
        log "NVIDIA GPU found but nvidia-container-toolkit is not configured; running on CPU."
    fi
fi

# ── Build the argument list for AUTOMATIC1111 ─────────────────────────────────
# --listen              bind to 0.0.0.0 so the host can reach the UI
# --port 7860           explicit port
# --disable-safe-unpickle   skip the pickle safety check (allows all models)
# --no-download-sd-model    do not auto-download the default SD model (we provide ours)
# --api                 enable the REST API
# --allow-code          allow arbitrary Python in the prompt processing pipeline
#
# CPU-only flags (omitted when a GPU is present):
# --skip-torch-cuda-test   skip the CUDA smoke test on startup
# --no-half                run in FP32 (required on CPU; FP16 is GPU-only)
# --precision full         equivalent to --no-half

WEBUI_ARGS="--listen --port 7860 --disable-safe-unpickle --no-download-sd-model --api --allow-code"
if [[ "${USE_GPU}" == "false" ]]; then
    WEBUI_ARGS="${WEBUI_ARGS} --skip-torch-cuda-test --no-half --precision full"
fi

# ── Build docker run arguments ────────────────────────────────────────────────
DOCKER_RUN_ARGS=(
    --name "${CONTAINER_NAME}"
    --rm
    -p "${PORT}:7860"
    -v "${DATA_DIR}/models/Stable-diffusion:/app/models/Stable-diffusion"
    -v "${DATA_DIR}/outputs:/app/outputs"
    -v "${DATA_DIR}/venv:/app/venv"
    -v "${DATA_DIR}/extensions:/app/extensions"
    -e "COMMANDLINE_ARGS=${WEBUI_ARGS}"
)

if [[ "${USE_GPU}" == "true" ]]; then
    DOCKER_RUN_ARGS+=(--gpus all)
fi

# ── Launch ────────────────────────────────────────────────────────────────────
log "=== Starting AUTOMATIC1111 Stable Diffusion WebUI (NO filter) ==="
log "  Web UI : http://localhost:${PORT}"
log "  API    : http://localhost:${PORT}/docs"
log ""
log "Note: on the very first start the container installs Python packages"
log "into the mounted venv — this can take 10-30 min. Subsequent starts"
log "reuse the cached venv and are much faster."
log ""
log "To stop  : press Ctrl+C"
log "To remove: $(basename "$0") -n"
log ""

docker_exec run "${DOCKER_RUN_ARGS[@]}" "${IMAGE_NAME}" bash webui.sh
