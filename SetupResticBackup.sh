#!/usr/bin/env bash

set -euo pipefail

DEFAULT_REPO_PATH="/srv/storage/OneDrive/Apps/Games/Storage/MattMC/Restic/"
DEFAULT_SOURCE_PATH="/srv/storage/Storage/Sync/MattMC/"

CONFIG_DIR="${HOME}/.config/restic-mattmc"
CONFIG_FILE="${CONFIG_DIR}/backup.env"
PASSWORD_FILE="${CONFIG_DIR}/password"

KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=12
KEEP_YEARLY=2

SERVICE_NAME="restic-mattmc-backup.service"
TIMER_NAME="restic-mattmc-backup.timer"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
TIMER_PATH="/etc/systemd/system/${TIMER_NAME}"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
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

random_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64
    echo
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

write_config() {
  local repo_path="$1"
  local source_path="$2"

  mkdir -p "${CONFIG_DIR}"

  if [[ ! -f "${PASSWORD_FILE}" ]]; then
    random_token >"${PASSWORD_FILE}"
    chmod 600 "${PASSWORD_FILE}"
  fi

  {
    printf 'RESTIC_REPOSITORY=%q\n' "${repo_path}"
    printf 'RESTIC_SOURCE=%q\n' "${source_path}"
    printf 'RESTIC_PASSWORD_FILE=%q\n' "${PASSWORD_FILE}"
    printf 'KEEP_DAILY=%q\n' "${KEEP_DAILY}"
    printf 'KEEP_WEEKLY=%q\n' "${KEEP_WEEKLY}"
    printf 'KEEP_MONTHLY=%q\n' "${KEEP_MONTHLY}"
    printf 'KEEP_YEARLY=%q\n' "${KEEP_YEARLY}"
  } >"${CONFIG_FILE}"

  chmod 600 "${CONFIG_FILE}"
}

load_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    log "Configuration not found. Run setup first."
    return 1
  fi

  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"

  if [[ -z "${RESTIC_REPOSITORY:-}" || -z "${RESTIC_SOURCE:-}" || -z "${RESTIC_PASSWORD_FILE:-}" ]]; then
    log "Error: configuration file is missing required fields."
    return 1
  fi

  return 0
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
  load_config || return 1
  validate_source_directory "${RESTIC_SOURCE}"
  ensure_repo_directory_writable "${RESTIC_REPOSITORY}"
  ensure_repo_initialized

  log "Starting backup: ${RESTIC_SOURCE}"
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
  local run_user
  run_user="${USER}"

  sudo tee "${SERVICE_PATH}" >/dev/null <<EOF
[Unit]
Description=Restic backup for MattMC data
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${run_user}
Group=${run_user}
ExecStart=${SCRIPT_PATH} --run-backup
EOF

  sudo tee "${TIMER_PATH}" >/dev/null <<EOF
[Unit]
Description=Daily Restic backup timer for MattMC data

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now "${TIMER_NAME}" >/dev/null

  log "Automatic backups enabled via ${TIMER_NAME}."
}

show_current_config() {
  if ! load_config; then
    return 1
  fi

  echo "=== Current Restic Backup Config ==="
  echo "Repository: ${RESTIC_REPOSITORY}"
  echo "Source:     ${RESTIC_SOURCE}"
  echo "Policy:     daily=${KEEP_DAILY} weekly=${KEEP_WEEKLY} monthly=${KEEP_MONTHLY} yearly=${KEEP_YEARLY}"
  echo "Service:    ${SERVICE_NAME}"
  echo "Timer:      ${TIMER_NAME}"
}

collect_snapshots() {
  local snapshot_output
  snapshot_output="$(restic_cmd snapshots --compact 2>/dev/null || true)"

  mapfile -t SNAPSHOT_LINES < <(printf '%s\n' "${snapshot_output}" | awk 'NR>2 && NF>0 {print $1"|"$2" "$3}')
}

list_snapshots_with_sizes() {
  ensure_restic_installed
  load_config || return 1
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
  load_config || return 1
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
  load_config || return 1
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

  local repo_path source_path
  prompt_path "Enter restic repository path" "${DEFAULT_REPO_PATH}" repo_path
  prompt_path "Enter source path to back up" "${DEFAULT_SOURCE_PATH}" source_path

  ensure_repo_directory_writable "${repo_path}"
  validate_source_directory "${source_path}"

  write_config "${repo_path}" "${source_path}"
  load_config
  ensure_repo_initialized
  setup_systemd_timer

  log "Setup complete."
  show_current_config
}

print_menu() {
  echo
  echo "=== Restic Backup Manager ==="
  echo "1) Run / rerun setup"
  echo "2) Take immediate backup now"
  echo "3) List backups (dates + sizes)"
  echo "4) Restore snapshot to Downloads"
  echo "5) Run forget + prune now"
  echo "6) Show current configuration"
  echo "7) Exit"
  echo
}

main_loop() {
  local choice
  while true; do
    print_menu
    read -r -p "Choose an option [1-7]: " choice

    case "${choice}" in
      1)
        run_setup_flow
        ;;
      2)
        run_backup_now
        ;;
      3)
        list_snapshots_with_sizes
        ;;
      4)
        restore_snapshot_to_downloads
        ;;
      5)
        run_forget_prune_now
        ;;
      6)
        show_current_config
        ;;
      7)
        echo "Goodbye."
        exit 0
        ;;
      *)
        echo "Invalid selection."
        ;;
    esac
  done
}

if [[ "${1:-}" == "--run-backup" ]]; then
  run_backup_now
  exit 0
fi

main_loop
