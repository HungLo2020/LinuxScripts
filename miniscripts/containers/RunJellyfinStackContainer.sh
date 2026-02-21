#!/usr/bin/env bash
# =============================================================================
# RunJellyfinStackContainer.sh
#
# Sets up and manages a Docker media stack:
#   - Jellyfin
#   - Radarr
#   - Sonarr
#   - Jackett
#   - qBittorrent (behind NordVPN via Gluetun kill-switch)
#
# Usage:
#   ./RunJellyfinStackContainer.sh          Install/update and start stack
#   ./RunJellyfinStackContainer.sh --on     Start stack only if installed
#   ./RunJellyfinStackContainer.sh --off    Stop stack without deleting data
#   ./RunJellyfinStackContainer.sh -D       Stop stack and delete stack files
# =============================================================================

set -euo pipefail

ACTION="run"
if [[ "$#" -gt 1 ]]; then
  echo "Error: too many arguments. Use -D, --on, --off, or no flag."
  exit 1
fi
if [[ "$#" -eq 1 ]]; then
  case "$1" in
    -D) ACTION="delete" ;;
    --on) ACTION="on" ;;
    --off) ACTION="off" ;;
    *)
      echo "Error: unknown argument '$1'. Use -D, --on, --off, or no flag."
      exit 1
      ;;
  esac
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
while [[ "${REPO_ROOT}" != "/" && ! -d "${REPO_ROOT}/resources" ]]; do
  REPO_ROOT="$(dirname "${REPO_ROOT}")"
done

if [[ ! -d "${REPO_ROOT}/resources" ]]; then
  echo "Error: could not locate repository resources directory from ${SCRIPT_DIR}"
  exit 1
fi

RESOURCE_DIR="${REPO_ROOT}/resources/jellyfin"
COMPOSE_TEMPLATE="${RESOURCE_DIR}/docker-compose.yml"
ENV_TEMPLATE="${RESOURCE_DIR}/.env.example"

STACK_ROOT="${HOME}/.jellyfin-stack"
STACK_COMPOSE_FILE="${STACK_ROOT}/docker-compose.yml"
STACK_ENV_FILE="${STACK_ROOT}/.env"

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

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    if [[ "${ACTION}" != "run" ]]; then
      echo "Error: Docker is not installed."
      exit 1
    fi
    log "Docker not found. Installing via official script..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "${USER}" || true
    log "Docker installed. You may need to re-login for docker group permissions."
  fi

  if ! docker info >/dev/null 2>&1; then
    if sudo docker info >/dev/null 2>&1; then
      DOCKER_USE_SUDO="true"
      log "Using 'sudo docker' for this session."
    else
      echo "Error: cannot connect to Docker daemon."
      exit 1
    fi
  fi

  if ! compose_exec version >/dev/null 2>&1; then
    if [[ "${ACTION}" != "run" ]]; then
      echo "Error: Docker Compose is not available."
      exit 1
    fi

    log "Docker Compose not found. Installing docker-compose-plugin..."
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update
      sudo apt-get install -y docker-compose-plugin
    else
      echo "Error: couldn't auto-install compose plugin on this distro. Install Docker Compose manually."
      exit 1
    fi

    if ! compose_exec version >/dev/null 2>&1; then
      echo "Error: Docker Compose still not available after install."
      exit 1
    fi
  fi
}

validate_template_files() {
  if [[ ! -f "${COMPOSE_TEMPLATE}" ]]; then
    echo "Error: missing compose template: ${COMPOSE_TEMPLATE}"
    exit 1
  fi

  if [[ ! -f "${ENV_TEMPLATE}" ]]; then
    echo "Error: missing env template: ${ENV_TEMPLATE}"
    exit 1
  fi
}

prompt_non_empty() {
  local prompt="$1"
  local value=""
  while true; do
    read -r -p "$prompt" value
    if [[ -n "${value}" ]]; then
      echo "${value}"
      return 0
    fi
    echo "Value cannot be empty."
  done
}

prompt_absolute_existing_dir() {
  local prompt="$1"
  local path=""
  while true; do
    read -r -p "$prompt" path
    if [[ -z "${path}" ]]; then
      echo "Path cannot be empty."
      continue
    fi
    if [[ "${path}" != /* ]]; then
      echo "Please provide an absolute path starting with '/'."
      continue
    fi
    if [[ ! -d "${path}" ]]; then
      echo "Directory does not exist: ${path}"
      continue
    fi
    echo "${path}"
    return 0
  done
}

write_env_file() {
  local media_path="$1"
  local music_path="$2"
  local downloads_path="$3"
  local nord_user="$4"
  local nord_pass="$5"
  local nord_country="$6"

  mkdir -p "${STACK_ROOT}"
  cp -f "${ENV_TEMPLATE}" "${STACK_ENV_FILE}"

  local uid gid tz
  uid="$(id -u)"
  gid="$(id -g)"
  tz="${TZ:-America/Los_Angeles}"

  cat > "${STACK_ENV_FILE}" <<EOF
PUID=${uid}
PGID=${gid}
TZ=${tz}

STACK_ROOT=${STACK_ROOT}
MEDIA_PATH=${media_path}
MUSIC_PATH=${music_path}
DOWNLOADS_PATH=${downloads_path}

NORDVPN_USER=${nord_user}
NORDVPN_PASSWORD=${nord_pass}
NORDVPN_COUNTRY=${nord_country}

JELLYFIN_PORT=8096
RADARR_PORT=7878
SONARR_PORT=8989
JACKETT_PORT=9117
FLARESOLVERR_PORT=8191
QBITTORRENT_WEBUI_PORT=8080
QBITTORRENT_TORRENT_PORT=6881
EOF
}

copy_compose_file() {
  mkdir -p "${STACK_ROOT}"
  cp -f "${COMPOSE_TEMPLATE}" "${STACK_COMPOSE_FILE}"
}

print_qbittorrent_credentials() {
  local username="admin"
  local password_line=""
  local password_value=""
  local i

  for i in {1..15}; do
    password_line="$(docker_exec logs qbittorrent 2>&1 | grep -i 'temporary password' | tail -n1 || true)"
    if [[ -n "${password_line}" ]]; then
      break
    fi
    sleep 1
  done

  if [[ -n "${password_line}" ]]; then
    password_value="$(printf '%s' "${password_line}" | sed -E 's/.*session[: ]+//')"
    log "qBittorrent login username: ${username}"
    log "qBittorrent temporary password: ${password_value}"
    log "Change this in qBittorrent WebUI after first login."
  else
    log "qBittorrent login username: ${username}"
    log "Temporary password not found in logs (it may already be configured)."
    log "To inspect manually: sudo docker logs qbittorrent | grep -i password"
  fi
}

start_stack() {
  mkdir -p \
    "${STACK_ROOT}/config/jellyfin" \
    "${STACK_ROOT}/config/radarr" \
    "${STACK_ROOT}/config/sonarr" \
    "${STACK_ROOT}/config/jackett" \
    "${STACK_ROOT}/config/qbittorrent"

  compose_exec -f "${STACK_COMPOSE_FILE}" --env-file "${STACK_ENV_FILE}" pull
  compose_exec -f "${STACK_COMPOSE_FILE}" --env-file "${STACK_ENV_FILE}" up -d

  log "Stack started."
  log "Jellyfin:     http://localhost:8096"
  log "Radarr:       http://localhost:7878"
  log "Sonarr:       http://localhost:8989"
  log "Jackett:      http://localhost:9117"
  log "For Radarr/Sonarr indexer URL use: http://jackett:9117"
  log "FlareSolverr: internal to Jackett at http://localhost:8191"
  log "qBittorrent:  http://localhost:8080"
  print_qbittorrent_credentials
}

stop_stack() {
  if [[ ! -f "${STACK_COMPOSE_FILE}" || ! -f "${STACK_ENV_FILE}" ]]; then
    log "Stack is not installed. Nothing to stop."
    return 0
  fi

  compose_exec -f "${STACK_COMPOSE_FILE}" --env-file "${STACK_ENV_FILE}" stop || true
  log "Stack stopped."
}

delete_stack() {
  if [[ -f "${STACK_COMPOSE_FILE}" && -f "${STACK_ENV_FILE}" ]]; then
    compose_exec -f "${STACK_COMPOSE_FILE}" --env-file "${STACK_ENV_FILE}" down --remove-orphans || true
  fi

  if [[ -d "${STACK_ROOT}" ]]; then
    rm -rf "${STACK_ROOT}"
    log "Removed stack files: ${STACK_ROOT}"
  else
    log "Stack directory does not exist."
  fi
}

ensure_installed_for_on_off() {
  if [[ ! -f "${STACK_COMPOSE_FILE}" || ! -f "${STACK_ENV_FILE}" ]]; then
    echo "Error: stack not installed. Run without flags first."
    exit 1
  fi
}

validate_template_files
ensure_docker

case "${ACTION}" in
  delete)
    delete_stack
    ;;

  off)
    ensure_installed_for_on_off
    stop_stack
    ;;

  on)
    ensure_installed_for_on_off
    start_stack
    ;;

  run)
    log "Paste the absolute path to your existing media root directory."
    media_path="$(prompt_absolute_existing_dir 'Media path: ')"
    if [[ "${media_path}" != "/" ]]; then
      media_path="${media_path%/}"
    fi

    log "Paste a second absolute library path (tip: use your music directory)."
    music_path="$(prompt_absolute_existing_dir 'Second library path (music): ')"
    if [[ "${music_path}" != "/" ]]; then
      music_path="${music_path%/}"
    fi

    read -r -p "Downloads path (Enter for ${media_path}/downloads): " downloads_path
    if [[ -z "${downloads_path}" ]]; then
      downloads_path="${media_path}/downloads"
    fi

    if [[ "${downloads_path}" != /* ]]; then
      echo "Error: downloads path must be absolute."
      exit 1
    fi
    mkdir -p "${downloads_path}"

    nord_user="$(prompt_non_empty 'NordVPN username (service credentials): ')"
    nord_pass="$(prompt_non_empty 'NordVPN password (service credentials): ')"

    read -r -p "NordVPN country (Enter for United States): " nord_country
    if [[ -z "${nord_country}" ]]; then
      nord_country="United States"
    fi

    write_env_file "${media_path}" "${music_path}" "${downloads_path}" "${nord_user}" "${nord_pass}" "${nord_country}"
    copy_compose_file
    start_stack
    ;;
esac
