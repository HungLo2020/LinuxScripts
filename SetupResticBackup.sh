#!/usr/bin/env bash

set -euo pipefail

DEFAULT_REPO_PATH="/srv/storage/OneDrive/Apps/Games/Storage/MattMC/Restic/"
DEFAULT_SOURCE_PATH="/srv/storage/Storage/Sync/MattMC/"
DEFAULT_CONFIG_NAME="MattMC"

CONFIG_ROOT="${HOME}/.config/restic-mattmc"
CONFIGS_DIR="${CONFIG_ROOT}/configs"
CURRENT_CONFIG_FILE="${CONFIG_ROOT}/current_config"
LEGACY_CONFIG_FILE="${CONFIG_ROOT}/backup.env"
LEGACY_PASSWORD_FILE="${CONFIG_ROOT}/password"

KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=12
KEEP_YEARLY=2

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

ACTIVE_CONFIG_NAME=""
ACTIVE_CONFIG_SLUG=""
ACTIVE_CONFIG_FILE=""
RESTIC_REPOSITORY=""
RESTIC_SOURCE=""
RESTIC_PASSWORD_FILE=""
declare -a CONFIG_INDEX_SLUGS=()
declare -a CONFIG_INDEX_NAMES=()

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

ensure_config_dirs() {
  mkdir -p "${CONFIGS_DIR}"
  chmod 700 "${CONFIG_ROOT}" "${CONFIGS_DIR}" 2>/dev/null || true
}

collect_config_index() {
  local config_file slug name

  CONFIG_INDEX_SLUGS=()
  CONFIG_INDEX_NAMES=()

  ensure_config_dirs
  shopt -s nullglob
  for config_file in "${CONFIGS_DIR}"/*.env; do
    slug="$(basename "${config_file}" .env)"
    name=""
    # shellcheck disable=SC1090
    source "${config_file}"
    name="${CONFIG_NAME:-${slug}}"
    CONFIG_INDEX_SLUGS+=("${slug}")
    CONFIG_INDEX_NAMES+=("${name}")
  done
  shopt -u nullglob
}

normalize_path() {
  local input="$1"
  if [[ "${input}" == "/" ]]; then
    echo "/"
    return
  fi
  input="${input%/}"
  echo "${input}"
}

sanitize_config_name() {
  local input="$1"
  local slug

  slug="$(printf '%s' "${input}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  echo "${slug}"
}

config_file_for_slug() {
  local slug="$1"
  echo "${CONFIGS_DIR}/${slug}.env"
}

password_file_for_slug() {
  local slug="$1"
  echo "${CONFIGS_DIR}/password-${slug}.txt"
}

service_name_for_slug() {
  local slug="$1"
  echo "restic-${slug}-backup.service"
}

timer_name_for_slug() {
  local slug="$1"
  echo "restic-${slug}-backup.timer"
}

service_path_for_slug() {
  local slug="$1"
  echo "/etc/systemd/system/$(service_name_for_slug "${slug}")"
}

timer_path_for_slug() {
  local slug="$1"
  echo "/etc/systemd/system/$(timer_name_for_slug "${slug}")"
}

ensure_restic_installed() {
  if command -v restic >/dev/null 2>&1; then
    return 0
  fi

  log "restic is not installed. Attempting install..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y restic
  else
    log "Error: restic is missing and this distro is unsupported for auto-install."
    log "Install restic manually, then rerun this script."
    exit 1
  fi

  if ! command -v restic >/dev/null 2>&1; then
    log "Error: restic installation failed."
    exit 1
  fi
}

ensure_systemd_available() {
  if ! command -v systemctl >/dev/null 2>&1; then
    log "Error: systemctl is not available on this system."
    exit 1
  fi
}

random_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64
    echo
  fi
}

set_current_config_slug() {
  local slug="$1"
  ensure_config_dirs
  printf '%s\n' "${slug}" >"${CURRENT_CONFIG_FILE}"
}

get_current_config_slug() {
  if [[ -f "${CURRENT_CONFIG_FILE}" ]]; then
    tr -d '\n' <"${CURRENT_CONFIG_FILE}"
  fi
}

prompt_path() {
  local prompt_label="$1"
  local default_value="$2"
  local result_var="$3"
  local entered=""

  while true; do
    read -r -p "${prompt_label} [${default_value}]: " entered
    entered="${entered:-${default_value}}"

    if [[ -z "${entered}" ]]; then
      echo "Path cannot be empty."
      continue
    fi

    printf -v "${result_var}" '%s' "$(normalize_path "${entered}")"
    return 0
  done
}

prompt_config_name() {
  local result_name_var="$1"
  local result_slug_var="$2"
  local entered_name=""
  local entered_slug=""

  while true; do
    read -r -p "Enter backup config name [${DEFAULT_CONFIG_NAME}]: " entered_name
    entered_name="${entered_name:-${DEFAULT_CONFIG_NAME}}"

    if [[ -z "${entered_name}" ]]; then
      echo "Config name cannot be empty."
      continue
    fi

    entered_slug="$(sanitize_config_name "${entered_name}")"
    if [[ -z "${entered_slug}" ]]; then
      echo "Config name must include at least one letter or number."
      continue
    fi

    printf -v "${result_name_var}" '%s' "${entered_name}"
    printf -v "${result_slug_var}" '%s' "${entered_slug}"
    return 0
  done
}

ensure_repo_directory_writable() {
  local repo_path="$1"
  local probe_file="${repo_path}/.restic-write-probe"

  if [[ ! -d "${repo_path}" ]]; then
    if mkdir -p "${repo_path}" 2>/dev/null; then
      :
    else
      sudo mkdir -p "${repo_path}"
      sudo chown "${USER}:${USER}" "${repo_path}"
    fi
  fi

  if touch "${probe_file}" 2>/dev/null; then
    rm -f "${probe_file}"
    return 0
  fi

  if sudo touch "${probe_file}" >/dev/null 2>&1; then
    sudo chown "${USER}:${USER}" "${probe_file}" >/dev/null 2>&1 || true
    rm -f "${probe_file}" >/dev/null 2>&1 || sudo rm -f "${probe_file}" >/dev/null 2>&1 || true
    return 0
  fi

  log "Error: cannot write to repository path: ${repo_path}"
  exit 1
}

ensure_password_file_exists() {
  local password_path="$1"

  if [[ -f "${password_path}" ]]; then
    chmod 600 "${password_path}" 2>/dev/null || true
    return 0
  fi

  random_token >"${password_path}"
  chmod 600 "${password_path}"
}

validate_source_directory() {
  local source_path="$1"

  if [[ ! -d "${source_path}" ]]; then
    log "Error: source path does not exist: ${source_path}"
    exit 1
  fi

  if [[ ! -r "${source_path}" ]]; then
    log "Error: source path is not readable: ${source_path}"
    exit 1
  fi
}

write_config_file() {
  local config_name="$1"
  local config_slug="$2"
  local repo_path="$3"
  local source_path="$4"
  local password_file="$5"
  local config_file

  config_file="$(config_file_for_slug "${config_slug}")"

  {
    printf 'CONFIG_NAME=%q\n' "${config_name}"
    printf 'CONFIG_SLUG=%q\n' "${config_slug}"
    printf 'RESTIC_REPOSITORY=%q\n' "${repo_path}"
    printf 'RESTIC_SOURCE=%q\n' "${source_path}"
    printf 'RESTIC_PASSWORD_FILE=%q\n' "${password_file}"
    printf 'KEEP_DAILY=%q\n' "${KEEP_DAILY}"
    printf 'KEEP_WEEKLY=%q\n' "${KEEP_WEEKLY}"
    printf 'KEEP_MONTHLY=%q\n' "${KEEP_MONTHLY}"
    printf 'KEEP_YEARLY=%q\n' "${KEEP_YEARLY}"
  } >"${config_file}"

  chmod 600 "${config_file}"
}

migrate_legacy_config_if_needed() {
  local target_slug="mattmc"
  local target_file legacy_repo legacy_source legacy_password

  ensure_config_dirs
  target_file="$(config_file_for_slug "${target_slug}")"

  if [[ -f "${target_file}" || ! -f "${LEGACY_CONFIG_FILE}" ]]; then
    return 0
  fi

  # shellcheck disable=SC1090
  source "${LEGACY_CONFIG_FILE}"

  legacy_repo="${RESTIC_REPOSITORY:-}"
  legacy_source="${RESTIC_SOURCE:-}"
  legacy_password="${RESTIC_PASSWORD_FILE:-${LEGACY_PASSWORD_FILE}}"

  if [[ -z "${legacy_repo}" || -z "${legacy_source}" ]]; then
    return 0
  fi

  if [[ ! -f "${legacy_password}" ]]; then
    legacy_password="$(password_file_for_slug "${target_slug}")"
    ensure_password_file_exists "${legacy_password}"
  fi

  write_config_file "${DEFAULT_CONFIG_NAME}" "${target_slug}" "${legacy_repo}" "${legacy_source}" "${legacy_password}"
  set_current_config_slug "${target_slug}"
  log "Imported legacy backup config as '${DEFAULT_CONFIG_NAME}'."
}

resolve_config_slug() {
  local selector="$1"
  local slug normalized config_file
  local config_path config_name

  normalized="$(sanitize_config_name "${selector}")"
  if [[ -n "${normalized}" ]]; then
    config_file="$(config_file_for_slug "${normalized}")"
    if [[ -f "${config_file}" ]]; then
      echo "${normalized}"
      return 0
    fi
  fi

  shopt -s nullglob
  for config_path in "${CONFIGS_DIR}"/*.env; do
    config_name=""
    # shellcheck disable=SC1090
    source "${config_path}"
    config_name="${CONFIG_NAME:-}"
    if [[ -n "${config_name}" && "${config_name,,}" == "${selector,,}" ]]; then
      slug="$(basename "${config_path}" .env)"
      echo "${slug}"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob

  return 1
}

load_config_by_slug() {
  local slug="$1"
  local config_file

  config_file="$(config_file_for_slug "${slug}")"
  if [[ ! -f "${config_file}" ]]; then
    log "Configuration '${slug}' not found."
    return 1
  fi

  # shellcheck disable=SC1090
  source "${config_file}"

  if [[ -z "${CONFIG_NAME:-}" || -z "${RESTIC_REPOSITORY:-}" || -z "${RESTIC_SOURCE:-}" || -z "${RESTIC_PASSWORD_FILE:-}" ]]; then
    log "Error: configuration file is missing required fields."
    return 1
  fi

  ACTIVE_CONFIG_NAME="${CONFIG_NAME}"
  ACTIVE_CONFIG_SLUG="${slug}"
  ACTIVE_CONFIG_FILE="${config_file}"
  set_current_config_slug "${slug}"

  if [[ ! -f "${RESTIC_PASSWORD_FILE}" ]]; then
    log "Error: password file is missing for config '${ACTIVE_CONFIG_NAME}': ${RESTIC_PASSWORD_FILE}"
    return 1
  fi

  return 0
}

load_active_config() {
  local selector="${1:-}"
  local slug

  if [[ -n "${selector}" ]]; then
    if ! slug="$(resolve_config_slug "${selector}")"; then
      log "Error: no config found for selector '${selector}'."
      return 1
    fi
    load_config_by_slug "${slug}"
    return $?
  fi

  slug="$(get_current_config_slug || true)"
  if [[ -n "${slug}" && -f "$(config_file_for_slug "${slug}")" ]]; then
    load_config_by_slug "${slug}"
    return $?
  fi

  if ! select_config_interactively slug; then
    return 1
  fi

  load_config_by_slug "${slug}"
}

select_config_interactively() {
  local result_var="$1"
  local current_slug default_index choice selected_slug
  local idx=1
  local config_file slug name
  local -a slugs=()

  ensure_config_dirs
  shopt -s nullglob
  for config_file in "${CONFIGS_DIR}"/*.env; do
    slug="$(basename "${config_file}" .env)"
    name=""
    # shellcheck disable=SC1090
    source "${config_file}"
    name="${CONFIG_NAME:-${slug}}"
    slugs+=("${slug}")
    echo "${idx}) ${name} [${slug}]"
    ((idx++))
  done
  shopt -u nullglob

  if [[ "${#slugs[@]}" -eq 0 ]]; then
    log "No backup configs exist yet. Run setup first."
    return 1
  fi

  current_slug="$(get_current_config_slug || true)"
  default_index=1

  for idx in "${!slugs[@]}"; do
    if [[ "${slugs[$idx]}" == "${current_slug}" ]]; then
      default_index=$((idx + 1))
      break
    fi
  done

  while true; do
    read -r -p "Select config [${default_index}]: " choice
    choice="${choice:-${default_index}}"
    if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#slugs[@]} )); then
      selected_slug="${slugs[$((choice - 1))]}"
      set_current_config_slug "${selected_slug}"
      printf -v "${result_var}" '%s' "${selected_slug}"
      return 0
    fi
    echo "Please enter a valid number between 1 and ${#slugs[@]}."
  done
}

restic_cmd() {
  RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE}" restic -r "${RESTIC_REPOSITORY}" "$@"
}

ensure_repo_initialized() {
  if [[ -f "${RESTIC_REPOSITORY}/config" ]]; then
    if ! restic_cmd snapshots >/dev/null 2>&1; then
      log "Error: repository exists but could not be opened with current password."
      exit 1
    fi
    return 0
  fi

  log "Initializing restic repository at: ${RESTIC_REPOSITORY}"
  restic_cmd init
}

run_backup_now() {
  ensure_restic_installed
  load_active_config "${1:-}" || return 1
  validate_source_directory "${RESTIC_SOURCE}"
  ensure_repo_directory_writable "${RESTIC_REPOSITORY}"
  ensure_repo_initialized

  log "Starting backup for config '${ACTIVE_CONFIG_NAME}': ${RESTIC_SOURCE}"
  restic_cmd backup "${RESTIC_SOURCE}"

  log "Applying retention policy (daily=${KEEP_DAILY}, weekly=${KEEP_WEEKLY}, monthly=${KEEP_MONTHLY}, yearly=${KEEP_YEARLY})"
  restic_cmd forget --prune \
    --keep-daily "${KEEP_DAILY}" \
    --keep-weekly "${KEEP_WEEKLY}" \
    --keep-monthly "${KEEP_MONTHLY}" \
    --keep-yearly "${KEEP_YEARLY}"

  log "Backup + prune completed."
}

setup_systemd_timer() {
  local run_user service_name timer_name service_path timer_path
  run_user="${USER}"
  service_name="$(service_name_for_slug "${ACTIVE_CONFIG_SLUG}")"
  timer_name="$(timer_name_for_slug "${ACTIVE_CONFIG_SLUG}")"
  service_path="$(service_path_for_slug "${ACTIVE_CONFIG_SLUG}")"
  timer_path="$(timer_path_for_slug "${ACTIVE_CONFIG_SLUG}")"

  ensure_systemd_available

  sudo tee "${service_path}" >/dev/null <<EOF
[Unit]
Description=Restic backup for ${ACTIVE_CONFIG_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${run_user}
Group=${run_user}
ExecStart=${SCRIPT_PATH} --run-backup --config-name ${ACTIVE_CONFIG_SLUG}
EOF

  sudo tee "${timer_path}" >/dev/null <<EOF
[Unit]
Description=Daily Restic backup timer for ${ACTIVE_CONFIG_NAME}

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now "${timer_name}" >/dev/null

  log "Automatic backups enabled via ${timer_name}."
}

show_current_config() {
  if ! load_active_config "${1:-}"; then
    return 1
  fi

  local service_name timer_name
  service_name="$(service_name_for_slug "${ACTIVE_CONFIG_SLUG}")"
  timer_name="$(timer_name_for_slug "${ACTIVE_CONFIG_SLUG}")"

  echo "=== Current Restic Backup Config ==="
  echo "Name:       ${ACTIVE_CONFIG_NAME}"
  echo "Slug:       ${ACTIVE_CONFIG_SLUG}"
  echo "Repository: ${RESTIC_REPOSITORY}"
  echo "Source:     ${RESTIC_SOURCE}"
  echo "Policy:     daily=${KEEP_DAILY} weekly=${KEEP_WEEKLY} monthly=${KEEP_MONTHLY} yearly=${KEEP_YEARLY}"
  echo "Service:    ${service_name}"
  echo "Timer:      ${timer_name}"
}

list_all_configs() {
  local idx=1
  local config_file slug timer_name timer_state

  collect_config_index

  if [[ "${#CONFIG_INDEX_SLUGS[@]}" -eq 0 ]]; then
    echo "No backup configs found."
    return 0
  fi

  echo "=== All Backup Configs ==="
  for slug in "${CONFIG_INDEX_SLUGS[@]}"; do
    config_file="$(config_file_for_slug "${slug}")"
    # shellcheck disable=SC1090
    source "${config_file}"

    timer_name="$(timer_name_for_slug "${slug}")"
    timer_state="not-enabled"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled "${timer_name}" >/dev/null 2>&1; then
      timer_state="enabled"
    fi

    echo "${idx}) ${CONFIG_NAME:-${slug}} [${slug}]"
    echo "    Source: ${RESTIC_SOURCE:-unknown}"
    echo "    Repo:   ${RESTIC_REPOSITORY:-unknown}"
    echo "    Timer:  ${timer_name} (${timer_state})"
    ((idx++))
  done
}

is_password_file_used_by_other_configs() {
  local password_path="$1"
  local skip_slug="$2"
  local config_file slug candidate_password

  shopt -s nullglob
  for config_file in "${CONFIGS_DIR}"/*.env; do
    slug="$(basename "${config_file}" .env)"
    if [[ "${slug}" == "${skip_slug}" ]]; then
      continue
    fi

    candidate_password=""
    # shellcheck disable=SC1090
    source "${config_file}"
    candidate_password="${RESTIC_PASSWORD_FILE:-}"
    if [[ -n "${candidate_password}" && "${candidate_password}" == "${password_path}" ]]; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob

  return 1
}

is_repo_used_by_other_configs() {
  local repo_path="$1"
  local skip_slug="$2"
  local config_file slug candidate_repo

  shopt -s nullglob
  for config_file in "${CONFIGS_DIR}"/*.env; do
    slug="$(basename "${config_file}" .env)"
    if [[ "${slug}" == "${skip_slug}" ]]; then
      continue
    fi

    candidate_repo=""
    # shellcheck disable=SC1090
    source "${config_file}"
    candidate_repo="${RESTIC_REPOSITORY:-}"
    if [[ -n "${candidate_repo}" && "${candidate_repo}" == "${repo_path}" ]]; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob

  return 1
}

delete_config_by_index() {
  local index="$1"
  local slug name config_file password_file repo_path
  local timer_name service_name timer_path service_path
  local confirm delete_repo_choice current_slug

  collect_config_index

  if [[ "${#CONFIG_INDEX_SLUGS[@]}" -eq 0 ]]; then
    log "No configs to delete."
    return 0
  fi

  if [[ ! "${index}" =~ ^[0-9]+$ ]] || (( index < 1 || index > ${#CONFIG_INDEX_SLUGS[@]} )); then
    log "Invalid config number '${index}'. Use option 2 to see config numbers."
    return 1
  fi

  slug="${CONFIG_INDEX_SLUGS[$((index - 1))]}"
  name="${CONFIG_INDEX_NAMES[$((index - 1))]}"

  if ! load_config_by_slug "${slug}"; then
    return 1
  fi

  config_file="$(config_file_for_slug "${slug}")"
  password_file="${RESTIC_PASSWORD_FILE}"
  repo_path="${RESTIC_REPOSITORY}"
  service_name="$(service_name_for_slug "${slug}")"
  timer_name="$(timer_name_for_slug "${slug}")"
  service_path="$(service_path_for_slug "${slug}")"
  timer_path="$(timer_path_for_slug "${slug}")"

  read -r -p "Delete config '${name}' [${slug}] and associated service/timer? [y/N]: " confirm
  confirm="${confirm:-N}"
  if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    log "Delete cancelled."
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl disable --now "${timer_name}" >/dev/null 2>&1 || true
    sudo systemctl stop "${service_name}" >/dev/null 2>&1 || true
  fi

  sudo rm -f "${service_path}" "${timer_path}" >/dev/null 2>&1 || rm -f "${service_path}" "${timer_path}" || true

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl daemon-reload || true
    sudo systemctl reset-failed "${service_name}" "${timer_name}" >/dev/null 2>&1 || true
  fi

  rm -f "${config_file}"

  if [[ -f "${password_file}" ]]; then
    if is_password_file_used_by_other_configs "${password_file}" "${slug}"; then
      log "Password file is shared by another config; preserving ${password_file}."
    else
      rm -f "${password_file}"
    fi
  fi

  if is_repo_used_by_other_configs "${repo_path}" "${slug}"; then
    log "Repository is used by another config; preserving ${repo_path}."
  else
    read -r -p "Delete repository directory and backup data at '${repo_path}' too? [Y/n]: " delete_repo_choice
    delete_repo_choice="${delete_repo_choice:-Y}"
    if [[ "${delete_repo_choice}" =~ ^[Yy]$ ]]; then
      rm -rf "${repo_path}" >/dev/null 2>&1 || sudo rm -rf "${repo_path}"
      log "Deleted repository directory: ${repo_path}"
    else
      log "Repository preserved: ${repo_path}"
    fi
  fi

  current_slug="$(get_current_config_slug || true)"
  if [[ "${current_slug}" == "${slug}" ]]; then
    collect_config_index
    if [[ "${#CONFIG_INDEX_SLUGS[@]}" -gt 0 ]]; then
      set_current_config_slug "${CONFIG_INDEX_SLUGS[0]}"
    else
      rm -f "${CURRENT_CONFIG_FILE}"
    fi
  fi

  log "Deleted config '${name}' [${slug}]."
}

collect_snapshots() {
  local snapshot_output
  snapshot_output="$(restic_cmd snapshots --compact 2>/dev/null || true)"

  mapfile -t SNAPSHOT_LINES < <(printf '%s\n' "${snapshot_output}" | awk 'NR>2 && NF>0 {print $1"|"$2" "$3}')
}

list_snapshots_with_sizes() {
  ensure_restic_installed
  load_active_config "${1:-}" || return 1
  ensure_repo_initialized

  collect_snapshots

  if [[ "${#SNAPSHOT_LINES[@]}" -eq 0 ]]; then
    echo "No snapshots found."
    return 0
  fi

  printf "%-4s %-12s %-20s %s\n" "No." "Snapshot ID" "Date" "Approx Size"
  printf "%-4s %-12s %-20s %s\n" "----" "------------" "-------------------" "-----------"

  local index=1
  local line id when size
  for line in "${SNAPSHOT_LINES[@]}"; do
    id="${line%%|*}"
    when="${line#*|}"
    size="$(restic_cmd stats "${id}" --mode raw-data 2>/dev/null | sed -n 's/^[[:space:]]*Total Size:[[:space:]]*//p' | head -n1)"
    size="${size:-unknown}"
    printf "%-4s %-12s %-20s %s\n" "${index})" "${id}" "${when}" "${size}"
    ((index++))
  done
}

restore_snapshot_to_downloads() {
  ensure_restic_installed
  load_active_config "${1:-}" || return 1
  ensure_repo_initialized

  collect_snapshots

  if [[ "${#SNAPSHOT_LINES[@]}" -eq 0 ]]; then
    echo "No snapshots available to restore."
    return 0
  fi

  echo "Available snapshots:"
  local i=1
  local line id when
  for line in "${SNAPSHOT_LINES[@]}"; do
    id="${line%%|*}"
    when="${line#*|}"
    echo "${i}) ${id} (${when})"
    ((i++))
  done

  local choice=""
  while true; do
    read -r -p "Select snapshot number to restore to Downloads: " choice
    if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SNAPSHOT_LINES[@]} )); then
      break
    fi
    echo "Please enter a valid number between 1 and ${#SNAPSHOT_LINES[@]}."
  done

  line="${SNAPSHOT_LINES[$((choice - 1))]}"
  id="${line%%|*}"

  local restore_target="${HOME}/Downloads/restic-restore-${id}-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${restore_target}"

  log "Restoring snapshot ${id} to ${restore_target}"
  restic_cmd restore "${id}" --target "${restore_target}"
  log "Restore complete."
}

run_forget_prune_now() {
  ensure_restic_installed
  load_active_config "${1:-}" || return 1
  ensure_repo_initialized

  log "Running forget + prune policy now..."
  restic_cmd forget --prune \
    --keep-daily "${KEEP_DAILY}" \
    --keep-weekly "${KEEP_WEEKLY}" \
    --keep-monthly "${KEEP_MONTHLY}" \
    --keep-yearly "${KEEP_YEARLY}"

  log "Policy run complete."
}

run_setup_flow() {
  ensure_restic_installed
  ensure_config_dirs

  local repo_path source_path config_name config_slug
  local config_file password_file overwrite_choice=""

  prompt_path "Enter restic repository path" "${DEFAULT_REPO_PATH}" repo_path
  prompt_path "Enter source path to back up" "${DEFAULT_SOURCE_PATH}" source_path
  prompt_config_name config_name config_slug

  ensure_repo_directory_writable "${repo_path}"
  validate_source_directory "${source_path}"

  config_file="$(config_file_for_slug "${config_slug}")"
  password_file="$(password_file_for_slug "${config_slug}")"

  if [[ -f "${config_file}" ]]; then
    # shellcheck disable=SC1090
    source "${config_file}"
    if [[ -n "${RESTIC_PASSWORD_FILE:-}" ]]; then
      password_file="${RESTIC_PASSWORD_FILE}"
    fi

    read -r -p "Config '${config_name}' already exists. Overwrite paths/settings? [Y/n]: " overwrite_choice
    overwrite_choice="${overwrite_choice:-Y}"
    if [[ ! "${overwrite_choice}" =~ ^[Yy]$ ]]; then
      log "Setup cancelled."
      return 0
    fi
  fi

  ensure_password_file_exists "${password_file}"
  write_config_file "${config_name}" "${config_slug}" "${repo_path}" "${source_path}" "${password_file}"
  load_config_by_slug "${config_slug}"
  ensure_repo_initialized
  setup_systemd_timer

  log "Setup complete."
  show_current_config "${config_slug}"
}

print_menu() {
  echo
  echo "=== Restic Backup Manager ==="
  echo "1) Run / rerun setup"
  echo "2) List all configs"
  echo "3) Take immediate backup now"
  echo "4) List backups (dates + sizes)"
  echo "5) Restore snapshot to Downloads"
  echo "6) Run forget + prune now"
  echo "7) Show current configuration"
  echo "8) Exit"
  echo
  echo "Special commands:"
  echo "  delete <config-number>   Delete config + service/timer (example: delete 1)"
  echo "                           Use option 2 to see config numbers"
  echo
}

main_loop() {
  local choice
  while true; do
    print_menu
    read -r -p "Choose an option [1-8]: " choice

    if [[ "${choice}" =~ ^[Dd][Ee][Ll][Ee][Tt][Ee][[:space:]]+([0-9]+)$ ]]; then
      delete_config_by_index "${BASH_REMATCH[1]}"
      continue
    fi

    case "${choice}" in
      1)
        run_setup_flow
        ;;
      2)
        list_all_configs
        ;;
      3)
        run_backup_now
        ;;
      4)
        list_snapshots_with_sizes
        ;;
      5)
        restore_snapshot_to_downloads
        ;;
      6)
        run_forget_prune_now
        ;;
      7)
        show_current_config
        ;;
      8)
        echo "Goodbye."
        exit 0
        ;;
      *)
        echo "Invalid selection."
        ;;
    esac
  done
}

MODE="menu"
CONFIG_SELECTOR=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --run-backup)
      MODE="run-backup"
      shift
      ;;
    --config-name)
      if [[ "$#" -lt 2 ]]; then
        log "Error: --config-name requires a value."
        exit 1
      fi
      CONFIG_SELECTOR="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage:"
      echo "  ${0}                          # interactive menu"
      echo "  ${0} --run-backup [--config-name NAME_OR_SLUG]"
      exit 0
      ;;
    *)
      log "Error: unknown argument '$1'."
      exit 1
      ;;
  esac
done

ensure_config_dirs
migrate_legacy_config_if_needed

if [[ "${MODE}" == "run-backup" ]]; then
  run_backup_now "${CONFIG_SELECTOR}"
  exit 0
fi

main_loop
