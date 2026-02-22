#!/usr/bin/env bash
# =============================================================================
# RunWatchtowerContainer.sh
#
# Self-contained script to install and run Watchtower via Docker.
# Watchtower automatically keeps your other Docker containers up-to-date by
# pulling the latest images and recreating them.
#
# Usage:
#   ./RunWatchtowerContainer.sh          Install (if needed) and start Watchtower
#   ./RunWatchtowerContainer.sh -D       Stop container and delete all files/image
#   ./RunWatchtowerContainer.sh --off    Stop container without deleting files
#   ./RunWatchtowerContainer.sh --on     Start container only if already installed
#
# Notes:
#   - By default checks for updates every 24 hours (86400 seconds)
#   - Only containers with label com.centurylinklabs.watchtower.enable=true are
#     monitored unless WATCHTOWER_LABEL_ENABLE is set to false in the run command
#   - Persistent data: ~/.watchtower
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
CONTAINER_NAME="watchtower"
IMAGE_NAME="containrrr/watchtower:latest"
BASE_DATA_DIR="${HOME}/.watchtower"
# Check interval in seconds (default: 24 hours)
POLL_INTERVAL=86400

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

DOCKER_USE_SUDO="false"
docker_exec() {
    if [[ "${DOCKER_USE_SUDO}" == "true" ]]; then
        sudo docker "$@"
    else
        docker "$@"
    fi
}

container_exists() {
    docker_exec ps -aq --filter "name=^/$1$" 2>/dev/null | grep -q .
}

container_running() {
    docker_exec ps -q --filter "name=^/$1$" 2>/dev/null | grep -q .
}

# ── Parse action ──────────────────────────────────────────────────────────────
ACTION="run"
if [[ "$#" -gt 1 ]]; then
    log "Error: too many arguments."
    exit 1
fi

if [[ "$#" -eq 1 ]]; then
    case "$1" in
        -D)     ACTION="delete" ;;
        --off)  ACTION="off" ;;
        --on)   ACTION="on" ;;
        *)
            log "Error: unknown argument '$1'. Use -D, --off, or --on."
            exit 1
            ;;
    esac
fi

# ── Docker availability ───────────────────────────────────────────────────────
if [[ "${ACTION}" == "run" ]] && ! command -v docker &>/dev/null; then
    log "Docker not found. Installing via the official get.docker.com script..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "${USER}" || true
    log "Docker installed."
fi

if ! command -v docker &>/dev/null; then
    if [[ "${ACTION}" == "delete" ]]; then
        log "Warning: Docker not found; skipping container/image removal."
        if [[ -d "${BASE_DATA_DIR}" ]]; then
            log "Removing data directory: ${BASE_DATA_DIR}"
            rm -rf "${BASE_DATA_DIR}"
        else
            log "Data directory does not exist."
        fi
        log "=== Cleanup complete ==="
        exit 0
    fi
    log "Error: Docker is not installed."
    exit 1
fi

if ! docker info &>/dev/null; then
    if sudo docker info &>/dev/null; then
        DOCKER_USE_SUDO="true"
        log "Using 'sudo docker' for this session (user not yet in docker group)."
    else
        log "Error: cannot connect to the Docker daemon. Is Docker running?"
        exit 1
    fi
fi

# ── -D delete mode ────────────────────────────────────────────────────────────
if [[ "${ACTION}" == "delete" ]]; then
    log "=== Shutting down Watchtower and removing files ==="

    if container_running "${CONTAINER_NAME}"; then
        log "Stopping ${CONTAINER_NAME}..."
        docker_exec stop "${CONTAINER_NAME}" >/dev/null
    fi

    if container_exists "${CONTAINER_NAME}"; then
        log "Removing ${CONTAINER_NAME} container..."
        docker_exec rm "${CONTAINER_NAME}" >/dev/null
    fi

    if docker_exec images -q "${IMAGE_NAME}" 2>/dev/null | grep -q .; then
        log "Removing Watchtower image..."
        docker_exec rmi "${IMAGE_NAME}" >/dev/null || true
    fi

    if [[ -d "${BASE_DATA_DIR}" ]]; then
        log "Removing data directory: ${BASE_DATA_DIR}"
        rm -rf "${BASE_DATA_DIR}"
    else
        log "Data directory does not exist."
    fi

    log "=== Cleanup complete ==="
    exit 0
fi

# ── --off mode ────────────────────────────────────────────────────────────────
if [[ "${ACTION}" == "off" ]]; then
    if container_running "${CONTAINER_NAME}"; then
        log "Stopping ${CONTAINER_NAME}..."
        docker_exec stop "${CONTAINER_NAME}" >/dev/null
        log "Container stopped."
    else
        log "${CONTAINER_NAME} is not running."
    fi
    exit 0
fi

# ── --on checks ───────────────────────────────────────────────────────────────
if [[ "${ACTION}" == "on" ]]; then
    if ! docker_exec images -q "${IMAGE_NAME}" 2>/dev/null | grep -q .; then
        log "Error: Watchtower image is not installed. Run without flags first."
        exit 1
    fi
fi

mkdir -p "${BASE_DATA_DIR}"

if [[ "${ACTION}" == "run" ]]; then
    log "Pulling latest Watchtower image..."
    docker_exec pull "${IMAGE_NAME}" >/dev/null
fi

if container_running "${CONTAINER_NAME}"; then
    log "${CONTAINER_NAME} is already running."
    exit 0
fi

if container_exists "${CONTAINER_NAME}"; then
    log "Starting existing ${CONTAINER_NAME} container..."
    docker_exec start "${CONTAINER_NAME}" >/dev/null
else
    log "Creating and starting ${CONTAINER_NAME} container..."
    docker_exec run -d \
        --name "${CONTAINER_NAME}" \
        --restart unless-stopped \
        -e WATCHTOWER_POLL_INTERVAL="${POLL_INTERVAL}" \
        -e WATCHTOWER_CLEANUP=true \
        -v /var/run/docker.sock:/var/run/docker.sock \
        "${IMAGE_NAME}" >/dev/null
fi

log "=== Watchtower is running ==="
log "Watchtower will check for container image updates every $((POLL_INTERVAL / 3600)) hour(s)."
log "It will update ALL running containers automatically."
log "Use --off to stop, --on to start existing install, -D to fully remove."
