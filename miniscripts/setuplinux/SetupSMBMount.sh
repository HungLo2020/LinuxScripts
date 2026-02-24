#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BW_MASTER_PASSWORD_FILE="$PROJECT_ROOT/.bw_master_password"

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

SMB_USERNAME="matt"
SMB_SHARE_NAME="storage"
BITWARDEN_SMB_ITEM="PCPassword"
SMB_PASSWORD=""

if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
  echo "Error: Could not resolve home directory for user '$TARGET_USER'."
  exit 1
fi

run_as_target_user() {
  if [[ "$(id -un)" == "$TARGET_USER" ]]; then
    "$@"
  else
    sudo -H -u "$TARGET_USER" "$@"
  fi
}

bw_exec() {
  if [[ "$(id -un)" == "$TARGET_USER" ]]; then
    BW_SESSION="${BW_SESSION:-}" bw "$@"
  else
    sudo -H -u "$TARGET_USER" env BW_SESSION="${BW_SESSION:-}" bw "$@"
  fi
}

bitwarden_status() {
  local status_json
  local parsed

  status_json="$(bw_exec status 2>/dev/null || true)"
  parsed="$(printf '%s' "$status_json" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

  if [[ -z "$parsed" ]]; then
    echo "unknown"
  else
    echo "$parsed"
  fi
}

resolve_bitwarden_smb_password() {
  if ! command -v bw >/dev/null 2>&1; then
    echo "Error: Bitwarden CLI (bw) is not installed; cannot resolve SMB password from '${BITWARDEN_SMB_ITEM}'."
    exit 1
  fi

  echo "Resolving SMB password from Bitwarden item '${BITWARDEN_SMB_ITEM}'..."

  local status
  local session
  local password
  status="$(bitwarden_status)"

  if [[ "$status" == "unauthenticated" || "$status" == "unknown" ]]; then
    if [[ ! -t 0 ]]; then
      echo "Error: Bitwarden is unauthenticated and no interactive terminal is available for 'bw login'."
      exit 1
    fi

    echo "Bitwarden is not authenticated. Attempting 'bw login'..."
    if [[ "$(id -un)" == "$TARGET_USER" ]]; then
      if ! bw login </dev/tty >/dev/tty 2>&1; then
        echo "Error: Bitwarden login failed; cannot continue without SMB password."
        exit 1
      fi
    else
      if ! sudo -H -u "$TARGET_USER" bw login </dev/tty >/dev/tty 2>&1; then
        echo "Error: Bitwarden login failed; cannot continue without SMB password."
        exit 1
      fi
    fi
    status="$(bitwarden_status)"
  fi

  if [[ "$status" == "locked" ]]; then
    echo "Bitwarden vault is locked. Attempting 'bw unlock'..."
    if [[ -f "$BW_MASTER_PASSWORD_FILE" ]]; then
      echo "Using master password file for non-interactive unlock..."
      BW_MASTER_PASSWORD="$(<"$BW_MASTER_PASSWORD_FILE")"
      if [[ -z "$BW_MASTER_PASSWORD" ]]; then
        echo "Error: master password file exists but is empty: ${BW_MASTER_PASSWORD_FILE}"
        exit 1
      fi
      if [[ "$(id -un)" == "$TARGET_USER" ]]; then
        export BW_MASTER_PASSWORD
        session="$(bw unlock --passwordenv BW_MASTER_PASSWORD --nointeraction --raw 2>/dev/null || true)"
        unset BW_MASTER_PASSWORD
      else
        session="$(sudo -H -u "$TARGET_USER" env BW_MASTER_PASSWORD="$BW_MASTER_PASSWORD" bw unlock --passwordenv BW_MASTER_PASSWORD --nointeraction --raw 2>/dev/null || true)"
      fi
    else
      if [[ ! -t 0 ]]; then
        echo "Error: Bitwarden is locked and no master password file exists at ${BW_MASTER_PASSWORD_FILE}."
        exit 1
      fi

      if [[ "$(id -un)" == "$TARGET_USER" ]]; then
        session="$(bw unlock --raw </dev/tty 2>/dev/null || true)"
      else
        session="$(sudo -H -u "$TARGET_USER" bw unlock --raw </dev/tty 2>/dev/null || true)"
      fi
    fi

    session="$(printf '%s' "$session" | tr -d '\r\n')"

    if [[ -z "$session" ]]; then
      echo "Error: Bitwarden unlock failed; cannot continue without SMB password."
      exit 1
    fi

    export BW_SESSION="$session"
  fi

  password="$(bw_exec get password "$BITWARDEN_SMB_ITEM" 2>/dev/null || true)"

  if [[ -z "$password" ]]; then
    echo "Bitwarden password lookup returned empty; syncing vault and retrying..."
    bw_exec sync >/dev/null 2>&1 || true
    password="$(bw_exec get password "$BITWARDEN_SMB_ITEM" 2>/dev/null || true)"
  fi

  if [[ -z "$password" ]]; then
    password="$(bw_exec list items --search "$BITWARDEN_SMB_ITEM" --raw 2>/dev/null | python3 - "$BITWARDEN_SMB_ITEM" <<'PY'
import json
import sys

target = sys.argv[1].strip().lower()

try:
    items = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)

for item in items:
    name = (item.get("name") or "").strip().lower()
    if name != target:
        continue

    login = item.get("login") or {}
    pw = (login.get("password") or "").strip()
    if pw:
        print(pw)
        raise SystemExit(0)

print("")
PY
)"
  fi

  if [[ -z "$password" ]]; then
    echo "Error: Bitwarden item '${BITWARDEN_SMB_ITEM}' not found or has no password."
    exit 1
  fi

  SMB_PASSWORD="$password"
}

ensure_smb_client() {
  local missing=()

  if ! command -v smbclient >/dev/null 2>&1; then
    missing+=("smbclient")
  fi

  if ! command -v mount.cifs >/dev/null 2>&1; then
    missing+=("cifs-utils")
  fi

  if [[ ${#missing[@]} -eq 0 ]]; then
    echo "SMB client prerequisites already installed."
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Error: missing SMB prerequisites (${missing[*]}), and apt-get is unavailable for auto-install."
    exit 1
  fi

  echo "Installing SMB prerequisites: ${missing[*]}"
  sudo apt-get update
  sudo apt-get install -y "${missing[@]}"

  if ! command -v smbclient >/dev/null 2>&1 || ! command -v mount.cifs >/dev/null 2>&1; then
    echo "Error: SMB prerequisites are still missing after install attempt."
    exit 1
  fi
}

ensure_tailscale_ready() {
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "Error: tailscale is not installed. Install and log in to tailscale before running this script."
    exit 1
  fi

  local status_json
  if ! status_json="$(tailscale status --json 2>/dev/null)"; then
    echo "Error: tailscale is not running or not logged in. Start tailscaled and connect with 'tailscale up' first."
    exit 1
  fi

  local readiness
  readiness="$(python3 - <<'PY' "$status_json"
import json, sys

data = json.loads(sys.argv[1])
backend = data.get("BackendState", "")
self_node = data.get("Self") or {}
online = bool(self_node.get("Online", False))

if backend != "Running":
    print(f"ERR\tTailscale backend state is '{backend or 'unknown'}' (expected 'Running').")
    raise SystemExit(0)

if not self_node:
    print("ERR\tNo active Tailscale node identity found (not logged in).")
    raise SystemExit(0)

if not online:
    print("ERR\tTailscale is logged in but currently offline/disconnected.")
    raise SystemExit(0)

print("OK")
PY
)"

  if [[ "$readiness" != "OK" ]]; then
    echo "Error: ${readiness#ERR$'\t'}"
    echo "This script does not install, start, or log in to tailscale automatically."
    exit 1
  fi
}

find_target_tailscale_peer() {
  local status_json
  status_json="$(tailscale status --json)"

  python3 - <<'PY' "$status_json"
import json
import sys

data = json.loads(sys.argv[1])
targets = {"hunglosvr", "hunglosvr-1"}
matches = []

for peer in (data.get("Peer") or {}).values():
    if not peer.get("Online", False):
        continue

    host_name = (peer.get("HostName") or "").strip()
    dns_name = (peer.get("DNSName") or "").strip()
    dns_short = dns_name.split(".", 1)[0].strip() if dns_name else ""
    names = {host_name.lower(), dns_short.lower()}

    if not (names & targets):
        continue

    tailscale_ips = peer.get("TailscaleIPs") or []
    if not tailscale_ips:
        continue

    display_name = host_name or dns_short or "unknown"
    matches.append((display_name, tailscale_ips[0]))

if len(matches) == 0:
    print("ERR_NONE")
    raise SystemExit(0)

if len(matches) > 1:
    rendered = ", ".join(f"{name} ({ip})" for name, ip in matches)
    print(f"ERR_MULTI\t{rendered}")
    raise SystemExit(0)

name, ip = matches[0]
print(f"OK\t{name}\t{ip}")
PY
}

validate_share_access() {
  local server_ip="$1"
  local share_name="$2"
  local username="$3"
  local password="$4"

  smbclient "//${server_ip}/${share_name}" -U "${username}%${password}" -c 'quit' >/dev/null 2>&1
}

mount_with_cifs() {
  local server_ip="$1"
  local share_name="$2"
  local username="$3"
  local password="$4"
  local mount_point="$5"

  local target_uid target_gid cred_file mount_opts
  target_uid="$(id -u "$TARGET_USER")"
  target_gid="$(id -g "$TARGET_USER")"

  sudo mkdir -p "$mount_point"

  if grep -qs " ${mount_point} " /proc/mounts; then
    echo "Share already mounted at ${mount_point}."
    return 0
  fi

  cred_file="$(mktemp)"
  chmod 600 "$cred_file"
  {
    printf 'username=%s\n' "$username"
    printf 'password=%s\n' "$password"
  } > "$cred_file"

  mount_opts="credentials=${cred_file},uid=${target_uid},gid=${target_gid},iocharset=utf8,noperm"

  if sudo mount -t cifs "//${server_ip}/${share_name}" "$mount_point" -o "$mount_opts"; then
    rm -f "$cred_file"
    echo "Mounted //${server_ip}/${share_name} at ${mount_point}."
    return 0
  fi

  rm -f "$cred_file"
  return 1
}

add_dolphin_remote_place() {
  local smb_url="$1"
  local place_name="$2"

  if ! command -v dolphin >/dev/null 2>&1; then
    echo "Dolphin is not installed; skipping Dolphin remote entry setup."
    return 0
  fi

  local places_file="${TARGET_HOME}/.local/share/user-places.xbel"
  run_as_target_user mkdir -p "${TARGET_HOME}/.local/share"

  run_as_target_user python3 - <<'PY' "$places_file" "$smb_url" "$place_name"
import os
import sys
import xml.etree.ElementTree as ET

places_file, smb_url, place_name = sys.argv[1], sys.argv[2], sys.argv[3]

if os.path.exists(places_file):
    try:
        tree = ET.parse(places_file)
        root = tree.getroot()
    except ET.ParseError:
        root = ET.Element("xbel", {"version": "1.0"})
        tree = ET.ElementTree(root)
else:
    root = ET.Element("xbel", {"version": "1.0"})
    tree = ET.ElementTree(root)

for bookmark in root.findall("bookmark"):
    if bookmark.get("href") == smb_url:
        print("EXISTS")
        raise SystemExit(0)

bookmark = ET.SubElement(root, "bookmark", {"href": smb_url})
title = ET.SubElement(bookmark, "title")
title.text = place_name

ET.indent(tree, space="  ")
tree.write(places_file, encoding="utf-8", xml_declaration=True)
print("ADDED")
PY
}

ensure_smb_client
ensure_tailscale_ready

peer_result="$(find_target_tailscale_peer)"

if [[ "$peer_result" == "ERR_NONE" ]]; then
  echo "Error: no online tailscale peer found matching hostname 'HungLoSVR' or 'hunglosvr-1'."
  exit 1
fi

if [[ "$peer_result" == ERR_MULTI$'\t'* ]]; then
  echo "Error: multiple tailscale peers matched 'HungLoSVR' or 'hunglosvr-1': ${peer_result#ERR_MULTI$'\t'}"
  exit 1
fi

if [[ "$peer_result" != OK$'\t'* ]]; then
  echo "Error: failed to resolve matching tailscale peer."
  exit 1
fi

IFS=$'\t' read -r _ matched_name matched_ip <<< "$peer_result"

echo "Found \"${matched_name}\" at ${matched_ip} on tailscale."

resolve_bitwarden_smb_password

share_name="$SMB_SHARE_NAME"
smb_username="$SMB_USERNAME"
smb_password="$SMB_PASSWORD"

echo "Using SMB share '${share_name}' with username '${smb_username}'."

if ! validate_share_access "$matched_ip" "$share_name" "$smb_username" "$smb_password"; then
  echo "Error: share '${share_name}' is not reachable at //${matched_ip}/${share_name} with configured Bitwarden credentials."
  exit 1
fi

smb_url="smb://${matched_ip}/${share_name}"
safe_host="$(printf '%s' "$matched_name" | sed -E 's/[^[:alnum:]_. -]+/-/g; s/[ ]+/-/g; s/^-+//; s/-+$//')"
safe_share="$(printf '%s' "$share_name" | sed -E 's/[^[:alnum:]_. -]+/-/g; s/[ ]+/-/g; s/^-+//; s/-+$//')"
mount_point="/mnt/${safe_host:-HungLoSVR}-${safe_share:-share}"

echo "Mounting SMB share: //${matched_ip}/${share_name}"
if ! mount_with_cifs "$matched_ip" "$share_name" "$smb_username" "$smb_password" "$mount_point"; then
  echo "Error: credentialed cifs mount failed for //${matched_ip}/${share_name}."
  exit 1
fi

add_dolphin_remote_place "$smb_url" "HungLoSVR SMB"

echo "SMB mount setup complete."