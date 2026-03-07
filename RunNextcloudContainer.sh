#!/usr/bin/env bash

set -euo pipefail

PORT=8082
DEFAULT_ADMIN_USER="admin"
BASE_DATA_DIR="${HOME}/.nextcloud"
NEXTCLOUD_APP_DIR="${BASE_DATA_DIR}/app"
DB_DIR="${BASE_DATA_DIR}/db"
ENV_FILE="${BASE_DATA_DIR}/.env"
COMPOSE_FILE="${BASE_DATA_DIR}/docker-compose.yml"

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
DOCKER_USE_SUDO="false"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

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

random_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 24
    else
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
        echo
    fi
}

read_env_value() {
    local key="$1"
    if [[ ! -f "${ENV_FILE}" ]]; then
        return 1
    fi
    sed -n "s/^${key}=//p" "${ENV_FILE}" | tail -n1
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
        log "Error: Docker is not installed. Install Docker and rerun this script."
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        if sudo docker info >/dev/null 2>&1; then
            DOCKER_USE_SUDO="true"
            log "Using 'sudo docker' for this run."
        else
            log "Error: cannot connect to Docker daemon."
            exit 1
        fi
    fi

    if ! compose_exec version >/dev/null 2>&1; then
        log "Error: Docker Compose is not available. Install Docker Compose and rerun."
        exit 1
    fi
}

prompt_external_data_dir() {
    local current_path="$1"
    local path=""

    while true; do
        if [[ -n "${current_path}" ]]; then
            read -r -p "Enter absolute path for Nextcloud data directory [${current_path}]: " path
            path="${path:-${current_path}}"
        else
            read -r -p "Enter absolute path for Nextcloud data directory: " path
        fi

        if [[ -z "${path}" ]]; then
            echo "Path cannot be empty."
            continue
        fi

        if [[ "${path}" != /* ]]; then
            echo "Please provide an absolute path starting with '/'."
            continue
        fi

        if [[ "${path}" =~ [[:space:]] ]]; then
            echo "Please provide a path without spaces."
            continue
        fi

        if [[ ! -d "${path}" ]]; then
            local create_choice=""
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

write_env_file() {
    local external_data_dir="$1"
    local db_root_password="$(read_env_value "MYSQL_ROOT_PASSWORD" || true)"
    local db_password="$(read_env_value "MYSQL_PASSWORD" || true)"
    local redis_password="$(read_env_value "REDIS_PASSWORD" || true)"
    local admin_user="$(read_env_value "NEXTCLOUD_ADMIN_USER" || true)"
    local admin_password="$(read_env_value "NEXTCLOUD_ADMIN_PASSWORD" || true)"

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

sync_compose_template() {
    if [[ ! -f "${COMPOSE_TEMPLATE}" ]]; then
        log "Error: missing compose template: ${COMPOSE_TEMPLATE}"
        exit 1
    fi

    cp "${COMPOSE_TEMPLATE}" "${COMPOSE_FILE}"
}

print_access_summary() {
    local selected_dir="$1"
    log "Nextcloud is running."
    log "URL: http://localhost:${PORT}"
    log "Port: ${PORT}"
    log "Data directory: ${selected_dir}"
}

ensure_docker
mkdir -p "${NEXTCLOUD_APP_DIR}" "${DB_DIR}"

existing_external_dir="$(read_env_value "NEXTCLOUD_EXTERNAL_DATA_DIR" || true)"
selected_external_dir="$(prompt_external_data_dir "${existing_external_dir}")"

write_env_file "${selected_external_dir}"
sync_compose_template

log "Starting Nextcloud stack..."
compose_exec -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d

for _ in {1..90}; do
    if curl -fsS "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then
        print_access_summary "${selected_external_dir}"
        exit 0
    fi
    sleep 1
done

log "Nextcloud stack started, but readiness check timed out."
print_access_summary "${selected_external_dir}"
exit 0
