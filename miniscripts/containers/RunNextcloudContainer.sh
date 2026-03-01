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
#   - External data directory is prompted on first run and persisted
#   - DB path is default/fixed at ~/.nextcloud/db
#   - Compose template source: resources/nextcloud/docker-compose.yml
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
STACK_NAME="nextcloud"
NEXTCLOUD_CONTAINER_NAME="nextcloud-app"
DB_CONTAINER_NAME="nextcloud-db"
REDIS_CONTAINER_NAME="nextcloud-redis"
DEFAULT_ADMIN_USER="admin"

NEXTCLOUD_IMAGE="nextcloud:latest"
DB_IMAGE="mariadb:11"
REDIS_IMAGE="redis:7-alpine"

BASE_DATA_DIR="${HOME}/.nextcloud"
NEXTCLOUD_APP_DIR="${BASE_DATA_DIR}/app"
DB_DIR="${BASE_DATA_DIR}/db"
ENV_FILE="${BASE_DATA_DIR}/.env"
COMPOSE_FILE="${BASE_DATA_DIR}/docker-compose.yml"
PORT=8082

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
while [[ "${REPO_ROOT}" != "/" && ! -d "${REPO_ROOT}/resources" ]]; do
    REPO_ROOT="$(dirname "${REPO_ROOT}")"
done

if [[ ! -d "${REPO_ROOT}/resources" ]]; then
    echo "Error: could not locate repository resources directory from ${SCRIPT_DIR}"
    exit 1
fi

COMPOSE_TEMPLATE="${REPO_ROOT}/resources/nextcloud/docker-compose.yml"

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

ensure_dir_for_user() {
    local path="$1"

    if mkdir -p "${path}" 2>/dev/null; then
        return 0
    fi

    log "No write access to create ${path}; trying with sudo..."
    sudo mkdir -p "${path}"
    sudo chown "${USER}:${USER}" "${path}"
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
                ensure_dir_for_user "${path}"
            else
                echo "Please provide an existing directory."
                continue
            fi
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
    local db_root_password db_password redis_password admin_user admin_password

    db_root_password="$(read_env_value "MYSQL_ROOT_PASSWORD" || true)"
    db_password="$(read_env_value "MYSQL_PASSWORD" || true)"
    redis_password="$(read_env_value "REDIS_PASSWORD" || true)"
    admin_user="$(read_env_value "NEXTCLOUD_ADMIN_USER" || true)"
    admin_password="$(read_env_value "NEXTCLOUD_ADMIN_PASSWORD" || true)"

    [[ -n "${db_root_password}" ]] || db_root_password="$(random_token)"
    [[ -n "${db_password}" ]] || db_password="$(random_token)"
    [[ -n "${redis_password}" ]] || redis_password="$(random_token)"
    [[ -n "${admin_user}" ]] || admin_user="${DEFAULT_ADMIN_USER}"
    [[ -n "${admin_password}" ]] || admin_password="$(random_token)"

    cat >"${ENV_FILE}" <<EOF
NEXTCLOUD_PORT=${PORT}
NEXTCLOUD_APP_DIR=${NEXTCLOUD_APP_DIR}
NEXTCLOUD_EXTERNAL_DATA_DIR=${external_data_dir}
NEXTCLOUD_TRUSTED_DOMAINS=localhost 127.0.0.1
DB_DIR=${DB_DIR}

MYSQL_DATABASE=nextcloud
MYSQL_USER=nextcloud
MYSQL_PASSWORD=${db_password}
MYSQL_ROOT_PASSWORD=${db_root_password}

REDIS_PASSWORD=${redis_password}

NEXTCLOUD_ADMIN_USER=${admin_user}
NEXTCLOUD_ADMIN_PASSWORD=${admin_password}
EOF
}

print_access_summary() {
    local url="http://localhost:${PORT}"
    local admin_user admin_password external_data_dir

    admin_user="$(read_env_value "NEXTCLOUD_ADMIN_USER" || true)"
    admin_password="$(read_env_value "NEXTCLOUD_ADMIN_PASSWORD" || true)"
    external_data_dir="$(read_env_value "NEXTCLOUD_EXTERNAL_DATA_DIR" || true)"

    log "=== Nextcloud is ready ==="
    log "URL: ${url}"
    log "Port: ${PORT}"
    if [[ -n "${admin_user}" && -n "${admin_password}" ]]; then
        log "Username: ${admin_user}"
        log "Password: ${admin_password}"
    fi
    if [[ -n "${external_data_dir}" ]]; then
        log "Data directory: ${external_data_dir}"
    fi
    log "Use --off to stop, --on to start existing install, -D to fully remove."
}

sync_compose_template() {
    if [[ ! -f "${COMPOSE_TEMPLATE}" ]]; then
        log "Error: missing compose template: ${COMPOSE_TEMPLATE}"
        exit 1
    fi

    cp "${COMPOSE_TEMPLATE}" "${COMPOSE_FILE}"
}

stack_present() {
    [[ -f "${ENV_FILE}" && -f "${COMPOSE_FILE}" && -d "${NEXTCLOUD_APP_DIR}" && -d "${DB_DIR}" ]]
}

start_stack() {
    if [[ "${ACTION}" == "run" ]]; then
        log "Pulling latest images..."
        compose_exec -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" pull
    fi

    compose_exec -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d
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
        sync_compose_template
        compose_exec -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" down >/dev/null || true
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

    sync_compose_template
    compose_exec -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" stop
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
fi

if [[ ! -f "${ENV_FILE}" ]]; then
    log "Error: missing env configuration."
    exit 1
fi

sync_compose_template

if [[ "${ACTION}" == "on" ]] && container_running "${NEXTCLOUD_CONTAINER_NAME}" && container_running "${DB_CONTAINER_NAME}"; then
    print_access_summary
    exit 0
fi

start_stack

for _ in {1..90}; do
    if curl -fsS "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then
        print_access_summary
        exit 0
    fi
    sleep 1
done

log "Nextcloud stack started, but readiness check timed out."
log "Check logs with: docker logs -f ${NEXTCLOUD_CONTAINER_NAME}"
print_access_summary
exit 0
