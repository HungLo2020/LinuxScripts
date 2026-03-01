#!/usr/bin/env bash
# =============================================================================
# RunEmulatorJSContainer.sh
#
# Self-contained script to install and run EmulatorJS in Docker.
#
# Usage:
#   ./RunEmulatorJSContainer.sh          Install (if needed) and start EmulatorJS
#   ./RunEmulatorJSContainer.sh -D       Stop container and delete local files/image
#   ./RunEmulatorJSContainer.sh --off    Stop container without deleting files
#   ./RunEmulatorJSContainer.sh --on     Start container only if already installed
#
# Notes:
#   - Default exposed port: 8080
#   - ROMs directory (host): /srv/storage/OneDrive/Apps/Games/Emulators/Roms/
#   - Saves directory (host): /srv/storage/OneDrive/Apps/Games/Emulators/Saves/
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
CONTAINER_NAME="emulatorjs"
# Image chosen to match common EmulatorJS images on Docker Hub / GHCR.
IMAGE_NAME="emulatorjs/emulatorjs:latest"
BASE_DATA_DIR="${HOME}/.emulatorjs"
# Where roms and saves are stored on the host. Update these variables if you
# keep your files elsewhere. These defaults point to your requested OneDrive
# locations.
ROMS_DIR="/srv/storage/OneDrive/Apps/Games/Emulators/Roms"
SAVES_DIR="/srv/storage/OneDrive/Apps/Games/Emulators/Saves"
PORT=8080

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
while [[ "${REPO_ROOT}" != "/" && ! -d "${REPO_ROOT}/resources" ]]; do
    REPO_ROOT="$(dirname "${REPO_ROOT}")"
done

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
        -D)
            ACTION="delete"
            ;;
        --off)
            ACTION="off"
            ;;
        --on)
            ACTION="on"
            ;;
        *)
            log "Error: unknown argument '$1'. Use -D, --off, or --on."
            exit 1
            ;;
    esac
fi

# ── Docker availability / install ─────────────────────────────────────────────
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
    log "=== Shutting down EmulatorJS and removing files ==="

    if container_running "${CONTAINER_NAME}"; then
        log "Stopping ${CONTAINER_NAME}..."
        docker_exec stop "${CONTAINER_NAME}" >/dev/null || true
    else
        log "${CONTAINER_NAME} is not running."
    fi

    if container_exists "${CONTAINER_NAME}"; then
        log "Removing ${CONTAINER_NAME} container..."
        docker_exec rm "${CONTAINER_NAME}" >/dev/null || true
    else
        log "${CONTAINER_NAME} container does not exist."
    fi

    if docker_exec images -q "${IMAGE_NAME}" 2>/dev/null | grep -q .; then
        log "Removing EmulatorJS image..."
        docker_exec rmi "${IMAGE_NAME}" >/dev/null || true
    else
        log "EmulatorJS image does not exist."
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
        log "Error: EmulatorJS image is not installed. Run without flags first."
        exit 1
    fi

    if [[ ! -d "${ROMS_DIR}" ]]; then
        log "Error: ROMs directory does not exist: ${ROMS_DIR}"
        exit 1
    fi

    if [[ ! -d "${SAVES_DIR}" ]]; then
        log "Error: Saves directory does not exist: ${SAVES_DIR}"
        exit 1
    fi
fi

# ── Ensure folders and prepare files ─────────────────────────────────────────
mkdir -p "${BASE_DATA_DIR}" "${ROMS_DIR}" "${SAVES_DIR}"

if [[ "${ACTION}" == "run" ]]; then
    log "Pulling latest EmulatorJS image..."
    docker_exec pull "${IMAGE_NAME}" >/dev/null || true
fi

# ── Start or create container ─────────────────────────────────────────────────
if container_exists "${CONTAINER_NAME}"; then
    if container_running "${CONTAINER_NAME}"; then
        log "${CONTAINER_NAME} is already running at http://localhost:${PORT}"
        exit 0
    else
        log "Starting existing ${CONTAINER_NAME} container..."
        docker_exec start "${CONTAINER_NAME}" >/dev/null
        for _ in {1..30}; do
            if curl -fsS "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then
                log "EmulatorJS is ready at: http://localhost:${PORT}"
                exit 0
            fi
            sleep 1
        done
        log "Started, but readiness check timed out. Check logs: sudo docker logs -f ${CONTAINER_NAME}"
        exit 0
    fi
fi

log "Creating and starting ${CONTAINER_NAME} container..."

docker_exec run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    -p "${PORT}:80" \
    -v "${ROMS_DIR}:/app/roms:ro" \
    -v "${SAVES_DIR}:/app/saves" \
    -v "/var/run/docker.sock:/var/run/docker.sock:ro" \
    "${IMAGE_NAME}" >/dev/null

# ── Readiness check ───────────────────────────────────────────────────────────
for _ in {1..60}; do
    if curl -fsS "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then
        log "EmulatorJS is ready at: http://localhost:${PORT}"
        exit 0
    fi
    sleep 1
done

log "EmulatorJS container started, but readiness check timed out."
log "Check logs with: sudo docker logs -f ${CONTAINER_NAME}"
exit 0
