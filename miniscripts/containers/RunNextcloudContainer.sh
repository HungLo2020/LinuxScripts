#!/usr/bin/env bash
# =============================================================================
# RunNextcloudContainer.sh
#
# Self-contained script to install and run Nextcloud via Docker Compose.
#
# Usage:
#   ./RunNextcloudContainer.sh          Install (if needed) and start Nextcloud
#   ./RunNextcloudContainer.sh -D       Stop stack and delete local files/images
#   ./RunNextcloudContainer.sh --off    Stop stack without deleting files
#   ./RunNextcloudContainer.sh --on     Start stack only if already installed
#
# Notes:
#   - Nextcloud UI is exposed on http://localhost:8082
#   - External user data directory is prompted on first run and persisted
#   - Nextcloud app/config and DB files are stored in ~/.nextcloud
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
STACK_NAME="nextcloud"
NEXTCLOUD_CONTAINER_NAME="nextcloud-app"
DB_CONTAINER_NAME="nextcloud-db"
REDIS_CONTAINER_NAME="nextcloud-redis"

NEXTCLOUD_IMAGE="nextcloud:latest"
DB_IMAGE="mariadb:11"
REDIS_IMAGE="redis:7-alpine"

BASE_DATA_DIR="${HOME}/.nextcloud"
NEXTCLOUD_APP_DIR="${BASE_DATA_DIR}/app"
DB_DIR="${BASE_DATA_DIR}/db"
ENV_FILE="${BASE_DATA_DIR}/.env"
COMPOSE_FILE="${BASE_DATA_DIR}/docker-compose.yml"
PORT=8082

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

compose_exec() {
    if docker_exec compose version >/dev/null 2>&1; then
        docker_exec compose "$@"
        return 0
    fi

    if command -v docker-compose >/dev/null 2>&1; then
        if [[ "${DOCKER_USE_SUDO}" == "true" ]]; then
            sudo docker-compose "$@"
        else
            docker-compose "$@"
        fi
        return 0
    fi

    return 1
}

container_exists() {
    docker_exec ps -aq --filter "name=^/$1$" 2>/dev/null | grep -q .
}

container_running() {
    docker_exec ps -q --filter "name=^/$1$" 2>/dev/null | grep -q .
}

random_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 24
    else
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
        echo
    fi
}

ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        if [[ "${ACTION}" != "run" ]]; then
            log "Error: Docker is not installed."
            exit 1
        fi
        log "Docker not found. Installing via the official get.docker.com script..."
        curl -fsSL https://get.docker.com | sudo sh
        sudo usermod -aG docker "${USER}" || true
        log "Docker installed."
    fi

    if ! docker info >/dev/null 2>&1; then
        if sudo docker info >/dev/null 2>&1; then
            DOCKER_USE_SUDO="true"
            log "Using 'sudo docker' for this session (user not yet in docker group)."
        else
            log "Error: cannot connect to Docker daemon."
            exit 1
        fi
    fi

    if ! compose_exec version >/dev/null 2>&1; then
        if [[ "${ACTION}" != "run" ]]; then
            log "Error: Docker Compose is not available."
            exit 1
        fi
        log "Docker Compose not found. Installing docker-compose-plugin..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update
            sudo apt-get install -y docker-compose-plugin
        else
            log "Error: could not auto-install Docker Compose plugin on this distro."
            exit 1
        fi

        if ! compose_exec version >/dev/null 2>&1; then
            log "Error: Docker Compose is still unavailable after install."
            exit 1
        fi
    fi
}

prompt_external_data_dir() {
    local path=""
    while true; do
        read -r -p "Enter absolute path for Nextcloud external data directory: " path

        if [[ -z "${path}" ]]; then
            echo "Path cannot be empty."
            continue
        fi

        if [[ "${path}" != /* ]]; then
            echo "Please provide an absolute path starting with '/'."
            continue
        fi

        if [[ ! -d "${path}" ]]; then
            read -r -p "Directory does not exist. Create it now? [Y/n]: " create_choice
            create_choice="${create_choice:-Y}"
            if [[ "${create_choice}" =~ ^[Yy]$ ]]; then
                mkdir -p "${path}"
            else
                echo "Please provide an existing directory."
                continue
            fi
        fi

        local test_dir="${path}/.nextcloud-write-test-$$"
        if mkdir -p "${test_dir}" 2>/dev/null; then
            rmdir "${test_dir}" || true
        else
            echo "Directory is not writable by the current user: ${path}"
            echo "Fix permissions and try again."
            continue
        fi

        echo "${path}"
        return 0
    done
}

read_env_value() {
    local key="$1"
    if [[ ! -f "${ENV_FILE}" ]]; then
        return 1
    fi
    sed -n "s/^${key}=//p" "${ENV_FILE}" | tail -n1
}

write_env_file() {
    local external_data_dir="$1"
    local db_root_password db_password redis_password

    db_root_password="$(read_env_value "MYSQL_ROOT_PASSWORD" || true)"
    db_password="$(read_env_value "MYSQL_PASSWORD" || true)"
    redis_password="$(read_env_value "REDIS_PASSWORD" || true)"

    [[ -n "${db_root_password}" ]] || db_root_password="$(random_token)"
    [[ -n "${db_password}" ]] || db_password="$(random_token)"
    [[ -n "${redis_password}" ]] || redis_password="$(random_token)"

    cat >"${ENV_FILE}" <<EOF
NEXTCLOUD_PORT=${PORT}
NEXTCLOUD_APP_DIR=${NEXTCLOUD_APP_DIR}
NEXTCLOUD_EXTERNAL_DATA_DIR=${external_data_dir}
NEXTCLOUD_TRUSTED_DOMAINS=localhost 127.0.0.1

MYSQL_DATABASE=nextcloud
MYSQL_USER=nextcloud
MYSQL_PASSWORD=${db_password}
MYSQL_ROOT_PASSWORD=${db_root_password}

REDIS_PASSWORD=${redis_password}
EOF
}

write_compose_file() {
    cat >"${COMPOSE_FILE}" <<'EOF'
services:
  db:
    image: ${DB_IMAGE}
    container_name: nextcloud-db
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MYSQL_DATABASE=${MYSQL_DATABASE}
      - MYSQL_USER=${MYSQL_USER}
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
    volumes:
      - ${DB_DIR}:/var/lib/mysql

  redis:
    image: ${REDIS_IMAGE}
    container_name: nextcloud-redis
    restart: unless-stopped
    command: redis-server --requirepass ${REDIS_PASSWORD}

  app:
    image: ${NEXTCLOUD_IMAGE}
    container_name: nextcloud-app
    restart: unless-stopped
    depends_on:
      - db
      - redis
    ports:
      - ${NEXTCLOUD_PORT}:80
    environment:
      - MYSQL_HOST=db
      - MYSQL_DATABASE=${MYSQL_DATABASE}
      - MYSQL_USER=${MYSQL_USER}
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
      - REDIS_HOST=redis
      - REDIS_HOST_PASSWORD=${REDIS_PASSWORD}
      - NEXTCLOUD_TRUSTED_DOMAINS=${NEXTCLOUD_TRUSTED_DOMAINS}
    volumes:
      - ${NEXTCLOUD_APP_DIR}:/var/www/html
      - ${NEXTCLOUD_EXTERNAL_DATA_DIR}:/var/www/html/data
EOF
}

stack_present() {
    [[ -f "${ENV_FILE}" && -f "${COMPOSE_FILE}" && -d "${NEXTCLOUD_APP_DIR}" && -d "${DB_DIR}" ]]
}

compose_stack_exec() {
    export NEXTCLOUD_IMAGE DB_IMAGE REDIS_IMAGE DB_DIR
    compose_exec -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" "$@"
}

start_stack() {
    if [[ "${ACTION}" == "run" ]]; then
        log "Pulling latest images..."
        compose_stack_exec pull
    fi

    compose_stack_exec up -d
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

ensure_docker

# ── -D delete mode ────────────────────────────────────────────────────────────
if [[ "${ACTION}" == "delete" ]]; then
    log "=== Shutting down Nextcloud stack and removing local files ==="

    if stack_present; then
        compose_stack_exec down >/dev/null || true
    else
        if container_running "${NEXTCLOUD_CONTAINER_NAME}"; then
            docker_exec stop "${NEXTCLOUD_CONTAINER_NAME}" >/dev/null || true
        fi
        if container_running "${DB_CONTAINER_NAME}"; then
            docker_exec stop "${DB_CONTAINER_NAME}" >/dev/null || true
        fi
        if container_running "${REDIS_CONTAINER_NAME}"; then
            docker_exec stop "${REDIS_CONTAINER_NAME}" >/dev/null || true
        fi
        if container_exists "${NEXTCLOUD_CONTAINER_NAME}"; then
            docker_exec rm "${NEXTCLOUD_CONTAINER_NAME}" >/dev/null || true
        fi
        if container_exists "${DB_CONTAINER_NAME}"; then
            docker_exec rm "${DB_CONTAINER_NAME}" >/dev/null || true
        fi
        if container_exists "${REDIS_CONTAINER_NAME}"; then
            docker_exec rm "${REDIS_CONTAINER_NAME}" >/dev/null || true
        fi
    fi

    if docker_exec images -q "${NEXTCLOUD_IMAGE}" 2>/dev/null | grep -q .; then
        log "Removing Nextcloud image..."
        docker_exec rmi "${NEXTCLOUD_IMAGE}" >/dev/null || true
    fi
    if docker_exec images -q "${DB_IMAGE}" 2>/dev/null | grep -q .; then
        log "Removing MariaDB image..."
        docker_exec rmi "${DB_IMAGE}" >/dev/null || true
    fi
    if docker_exec images -q "${REDIS_IMAGE}" 2>/dev/null | grep -q .; then
        log "Removing Redis image..."
        docker_exec rmi "${REDIS_IMAGE}" >/dev/null || true
    fi

    external_dir="$(read_env_value "NEXTCLOUD_EXTERNAL_DATA_DIR" || true)"

    if [[ -d "${BASE_DATA_DIR}" ]]; then
        log "Removing local stack directory: ${BASE_DATA_DIR}"
        rm -rf "${BASE_DATA_DIR}"
    else
        log "Local stack directory does not exist."
    fi

    if [[ -n "${external_dir}" && -d "${external_dir}" ]]; then
        read -r -p "Delete external data directory too (${external_dir})? [y/N]: " delete_external
        delete_external="${delete_external:-N}"
        if [[ "${delete_external}" =~ ^[Yy]$ ]]; then
            log "Removing external data directory: ${external_dir}"
            rm -rf "${external_dir}"
        else
            log "External data directory preserved: ${external_dir}"
        fi
    fi

    log "=== Cleanup complete ==="
    exit 0
fi

# ── --off mode ────────────────────────────────────────────────────────────────
if [[ "${ACTION}" == "off" ]]; then
    if ! stack_present; then
        log "Nextcloud stack is not installed."
        exit 0
    fi

    compose_stack_exec stop
    log "Stack stopped."
    exit 0
fi

# ── --on checks ───────────────────────────────────────────────────────────────
if [[ "${ACTION}" == "on" ]]; then
    if ! stack_present; then
        log "Error: Nextcloud stack is not installed. Run without flags first."
        exit 1
    fi

    external_dir="$(read_env_value "NEXTCLOUD_EXTERNAL_DATA_DIR" || true)"
    if [[ -z "${external_dir}" || ! -d "${external_dir}" ]]; then
        log "Error: external data directory is missing. Run without flags to reconfigure."
        exit 1
    fi
fi

mkdir -p "${NEXTCLOUD_APP_DIR}" "${DB_DIR}"

if [[ "${ACTION}" == "run" ]]; then
    external_dir="$(read_env_value "NEXTCLOUD_EXTERNAL_DATA_DIR" || true)"
    if [[ -z "${external_dir}" ]]; then
        external_dir="$(prompt_external_data_dir)"
    fi

    write_env_file "${external_dir}"
    write_compose_file
fi

if [[ ! -f "${COMPOSE_FILE}" || ! -f "${ENV_FILE}" ]]; then
    log "Error: missing compose or env configuration."
    exit 1
fi

if container_running "${NEXTCLOUD_CONTAINER_NAME}" && container_running "${DB_CONTAINER_NAME}"; then
    log "${STACK_NAME} is already running at http://localhost:${PORT}"
    exit 0
fi

start_stack

for _ in {1..90}; do
    if curl -fsS "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then
        log "Nextcloud is ready at: http://localhost:${PORT}"
        log "Open in browser and complete the initial admin setup."
        exit 0
    fi
    sleep 1
done

log "Nextcloud stack started, but readiness check timed out."
log "Check logs with: docker logs -f ${NEXTCLOUD_CONTAINER_NAME}"
exit 0
