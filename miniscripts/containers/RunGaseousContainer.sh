#!/usr/bin/env bash
# =============================================================================
# RunGaseousContainer.sh
#
# Self-contained script to install and run Gaseous Server + MariaDB via Docker
# Compose (separate containers, as recommended by the Gaseous wiki).
#
# Usage:
#   ./RunGaseousContainer.sh          Install (if needed) and start stack
#   ./RunGaseousContainer.sh --on     Start stack only if already installed
#   ./RunGaseousContainer.sh --off    Stop stack without deleting files
#   ./RunGaseousContainer.sh -D       Stop stack and delete local files/images
#
# Notes:
#   - Gaseous UI is exposed on http://localhost:5198
#   - IGDB credentials are required and stored in ~/.gaseous/.env
#   - Persistent data is stored in ~/.gaseous/{gs,gsdb}
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
STACK_NAME="gaseous"
SERVER_CONTAINER_NAME="gaseous-server"
DB_CONTAINER_NAME="gsdb"

SERVER_IMAGE="gaseousgames/gaseousserver:latest"
DB_IMAGE="mariadb:latest"

BASE_DATA_DIR="${HOME}/.gaseous"
GS_DATA_DIR="${BASE_DATA_DIR}/gs"
GSDB_DATA_DIR="${BASE_DATA_DIR}/gsdb"
ENV_FILE="${BASE_DATA_DIR}/.env"
COMPOSE_FILE="${BASE_DATA_DIR}/docker-compose.yml"

PORT=5198
DEFAULT_TZ="$(cat /etc/timezone 2>/dev/null || echo UTC)"

ACTION="run"

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

prompt_nonempty_value() {
  local label="$1"
  local value
  while true; do
    read -r -p "Enter ${label}: " value
    if [[ -n "${value}" ]]; then
      echo "${value}"
      return 0
    fi
    echo "${label} cannot be empty."
  done
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

write_env_file() {
  local tz igdb_client_id igdb_client_secret mariadb_root_password mariadb_user mariadb_password

  tz="$(read_env_value "TZ" || true)"
  igdb_client_id="$(read_env_value "IGDB_CLIENT_ID" || true)"
  igdb_client_secret="$(read_env_value "IGDB_CLIENT_SECRET" || true)"
  mariadb_root_password="$(read_env_value "MARIADB_ROOT_PASSWORD" || true)"
  mariadb_user="$(read_env_value "MARIADB_USER" || true)"
  mariadb_password="$(read_env_value "MARIADB_PASSWORD" || true)"

  [[ -n "${tz}" ]] || tz="${DEFAULT_TZ}"
  [[ -n "${mariadb_root_password}" ]] || mariadb_root_password="$(random_token)"
  [[ -n "${mariadb_user}" ]] || mariadb_user="gaseous"
  [[ -n "${mariadb_password}" ]] || mariadb_password="$(random_token)"

  if [[ -z "${igdb_client_id}" ]]; then
    igdb_client_id="$(prompt_nonempty_value "IGDB Client ID")"
  fi

  if [[ -z "${igdb_client_secret}" ]]; then
    igdb_client_secret="$(prompt_nonempty_value "IGDB Client Secret")"
  fi

  cat >"${ENV_FILE}" <<EOF
GASEOUS_PORT=${PORT}
GASEOUS_DATA_DIR=${GS_DATA_DIR}
GASEOUS_DB_DIR=${GSDB_DATA_DIR}

TZ=${tz}
DB_HOST=${DB_CONTAINER_NAME}
DB_USER=root
DB_PASS=${mariadb_root_password}

IGDB_CLIENT_ID=${igdb_client_id}
IGDB_CLIENT_SECRET=${igdb_client_secret}

MARIADB_ROOT_PASSWORD=${mariadb_root_password}
MARIADB_USER=${mariadb_user}
MARIADB_PASSWORD=${mariadb_password}
EOF
}

write_compose_file() {
  cat >"${COMPOSE_FILE}" <<'EOF'
services:
  gaseous-server:
    container_name: gaseous-server
    image: gaseousgames/gaseousserver:latest
    restart: unless-stopped
    depends_on:
      - gsdb
    ports:
      - "${GASEOUS_PORT}:80"
    volumes:
      - "${GASEOUS_DATA_DIR}:/home/gaseous/.gaseous-server"
    environment:
      - TZ=${TZ}
      - dbhost=${DB_HOST}
      - dbuser=${DB_USER}
      - dbpass=${DB_PASS}
      - igdbclientid=${IGDB_CLIENT_ID}
      - igdbclientsecret=${IGDB_CLIENT_SECRET}
    networks:
      - gaseous

  gsdb:
    container_name: gsdb
    image: mariadb:latest
    restart: unless-stopped
    volumes:
      - "${GASEOUS_DB_DIR}:/var/lib/mysql"
    environment:
      - MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD}
      - MARIADB_USER=${MARIADB_USER}
      - MARIADB_PASSWORD=${MARIADB_PASSWORD}
    networks:
      - gaseous

networks:
  gaseous:
    name: gaseous
    driver: bridge
EOF
}

stack_installed() {
  [[ -f "${COMPOSE_FILE}" && -f "${ENV_FILE}" && -d "${GS_DATA_DIR}" && -d "${GSDB_DATA_DIR}" ]]
}

start_stack() {
  if [[ "${ACTION}" == "run" ]]; then
    compose_exec -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" pull
  fi

  compose_exec -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" up -d
}

off_stack() {
  if [[ ! -f "${COMPOSE_FILE}" || ! -f "${ENV_FILE}" ]]; then
    log "Nothing to stop. Stack files not found in ${BASE_DATA_DIR}."
    exit 0
  fi

  compose_exec -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" stop || true
  log "Gaseous stack stopped."
}

delete_stack() {
  log "=== Shutting down Gaseous stack and removing files ==="

  if command -v docker >/dev/null 2>&1; then
    if ! docker info >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
      DOCKER_USE_SUDO="true"
    fi

    if [[ -f "${COMPOSE_FILE}" && -f "${ENV_FILE}" ]] && compose_exec version >/dev/null 2>&1; then
      compose_exec -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" down --remove-orphans || true
    else
      docker_exec rm -f "${SERVER_CONTAINER_NAME}" >/dev/null 2>&1 || true
      docker_exec rm -f "${DB_CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi

    docker_exec rmi "${SERVER_IMAGE}" >/dev/null 2>&1 || true
    docker_exec rmi "${DB_IMAGE}" >/dev/null 2>&1 || true
  else
    log "Warning: Docker not found; skipping container/image removal."
  fi

  if [[ -d "${BASE_DATA_DIR}" ]]; then
    rm -rf "${BASE_DATA_DIR}"
  fi

  log "=== Cleanup complete ==="
}

ensure_runtime_dirs() {
  mkdir -p "${GS_DATA_DIR}" "${GSDB_DATA_DIR}"
}

validate_on_mode_requirements() {
  if ! stack_installed; then
    log "Error: stack files are not installed. Run without flags first."
    exit 1
  fi

  local igdb_client_id igdb_client_secret
  igdb_client_id="$(read_env_value "IGDB_CLIENT_ID" || true)"
  igdb_client_secret="$(read_env_value "IGDB_CLIENT_SECRET" || true)"

  if [[ -z "${igdb_client_id}" || -z "${igdb_client_secret}" ]]; then
    log "Error: IGDB credentials are missing in ${ENV_FILE}."
    log "Run without flags first to configure credentials."
    exit 1
  fi
}

# ── Parse action ──────────────────────────────────────────────────────────────
if [[ "$#" -gt 1 ]]; then
  log "Error: too many arguments. Use -D, --on, --off, or no flag."
  exit 1
fi

if [[ "$#" -eq 1 ]]; then
  case "$1" in
    -D)
      ACTION="delete"
      ;;
    --on)
      ACTION="on"
      ;;
    --off)
      ACTION="off"
      ;;
    *)
      log "Error: unknown argument '$1'. Use -D, --on, --off, or no flag."
      exit 1
      ;;
  esac
fi

# ── Main flow ─────────────────────────────────────────────────────────────────
case "${ACTION}" in
  delete)
    delete_stack
    exit 0
    ;;
  off)
    ensure_docker
    off_stack
    exit 0
    ;;
  on)
    ensure_docker
    validate_on_mode_requirements
    start_stack
    ;;
  run)
    ensure_docker
    ensure_runtime_dirs
    write_env_file
    write_compose_file
    start_stack
    ;;
esac

log "Gaseous stack started in detached mode."
log "Open: http://localhost:${PORT}"
log "Use --off to stop, --on to start existing install, -D to fully remove."
log "Check logs with: docker logs -f ${SERVER_CONTAINER_NAME}"
exit 0
