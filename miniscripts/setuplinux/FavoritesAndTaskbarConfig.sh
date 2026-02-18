#!/usr/bin/env bash

set -euo pipefail

# Add entries as: "package_name|desktop_file"
# Example: "code|code.desktop"
FAVORITES_PROGRAMS=(
  "firefox|firefox.desktop"
  "dolphin|org.kde.dolphin.desktop"
  "konsole|org.kde.konsole.desktop"
  "code|code.desktop"
  "steam|steam.desktop"
)

# Add entries as: "package_name|desktop_file"
TASKBAR_PROGRAMS=(
  "firefox|firefox.desktop"
  "dolphin|org.kde.dolphin.desktop"
  "konsole|org.kde.konsole.desktop"
  "steam|steam.desktop"
)

PLASMA_CONFIG_FILE="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"

if command -v kreadconfig6 >/dev/null 2>&1 && command -v kwriteconfig6 >/dev/null 2>&1; then
  KREAD="kreadconfig6"
  KWRITE="kwriteconfig6"
elif command -v kreadconfig5 >/dev/null 2>&1 && command -v kwriteconfig5 >/dev/null 2>&1; then
  KREAD="kreadconfig5"
  KWRITE="kwriteconfig5"
else
  echo "Error: kreadconfig/kwriteconfig (5 or 6) not found."
  exit 1
fi

if [[ ! -f "$PLASMA_CONFIG_FILE" ]]; then
  echo "Error: Plasma config not found at $PLASMA_CONFIG_FILE"
  exit 1
fi

contains_exact() {
  local needle="$1"
  shift
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

find_applet_location() {
  local plugin_name="$1"
  awk -v plugin="$plugin_name" '
    /^\[Containments\]\[[0-9]+\]\[Applets\]\[[0-9]+\]$/ {
      line=$0
      gsub(/^\[Containments\]\[/, "", line)
      split(line, parts, "]\[Applets\]\[")
      containment=parts[1]
      applet=parts[2]
      gsub(/\]$/, "", applet)
      next
    }
    /^plugin=/ {
      if ($0 == "plugin=" plugin) {
        print containment ":" applet
        exit
      }
    }
  ' "$PLASMA_CONFIG_FILE"
}

desktop_file_exists() {
  local desktop_file="$1"
  [[ -f "/usr/share/applications/$desktop_file" || -f "$HOME/.local/share/applications/$desktop_file" || -f "/var/lib/flatpak/exports/share/applications/$desktop_file" ]]
}

is_package_installed() {
  local package_name="$1"
  dpkg -s "$package_name" >/dev/null 2>&1
}

split_csv_to_array() {
  local csv="$1"
  local -n out_array_ref="$2"
  out_array_ref=()

  if [[ -z "$csv" ]]; then
    return
  fi

  local old_ifs="$IFS"
  IFS=',' read -r -a out_array_ref <<< "$csv"
  IFS="$old_ifs"
}

join_array_to_csv() {
  local -n in_array_ref="$1"
  local joined=""

  for value in "${in_array_ref[@]}"; do
    if [[ -z "$joined" ]]; then
      joined="$value"
    else
      joined+=",$value"
    fi
  done

  printf '%s' "$joined"
}

kickoff_location="$(find_applet_location "org.kde.plasma.kickoff")"
icontasks_location="$(find_applet_location "org.kde.plasma.icontasks")"

if [[ -z "$kickoff_location" ]]; then
  echo "Warning: kickoff applet not found. Favorites will be skipped."
else
  kickoff_containment="${kickoff_location%%:*}"
  kickoff_applet="${kickoff_location##*:}"
fi

if [[ -z "$icontasks_location" ]]; then
  echo "Warning: icontasks applet not found. Taskbar pinning will be skipped."
else
  icontasks_containment="${icontasks_location%%:*}"
  icontasks_applet="${icontasks_location##*:}"
fi

if [[ -n "${kickoff_containment:-}" && -n "${kickoff_applet:-}" ]]; then
  existing_favorites="$($KREAD --file "$PLASMA_CONFIG_FILE" \
    --group Containments --group "$kickoff_containment" --group Applets --group "$kickoff_applet" \
    --group Configuration --group General --key favoriteApps 2>/dev/null || true)"

  if [[ -z "$existing_favorites" ]]; then
    existing_favorites="$($KREAD --file "$PLASMA_CONFIG_FILE" \
      --group Containments --group "$kickoff_containment" --group Applets --group "$kickoff_applet" \
      --group Configuration --group General --key favorites 2>/dev/null || true)"
  fi

  split_csv_to_array "$existing_favorites" favorites_array

  for entry in "${FAVORITES_PROGRAMS[@]}"; do
    package_name="${entry%%|*}"
    desktop_file="${entry#*|}"
    launcher_entry="applications:$desktop_file"

    if ! is_package_installed "$package_name"; then
      echo "Favorites: skipping $desktop_file ($package_name not installed)"
      continue
    fi

    if ! desktop_file_exists "$desktop_file"; then
      echo "Favorites: skipping $desktop_file (desktop file not found)"
      continue
    fi

    if contains_exact "$launcher_entry" "${favorites_array[@]}"; then
      echo "Favorites: already present $desktop_file"
      continue
    fi

    favorites_array+=("$launcher_entry")
    echo "Favorites: added $desktop_file"
  done

  favorites_csv="$(join_array_to_csv favorites_array)"

  # Prefer config-based favorites for predictable script behavior.
  "$KWRITE" --file "$PLASMA_CONFIG_FILE" \
    --group Containments --group "$kickoff_containment" --group Applets --group "$kickoff_applet" \
    --group Configuration --group General --key favoritesPortedToKAstats false

  "$KWRITE" --file "$PLASMA_CONFIG_FILE" \
    --group Containments --group "$kickoff_containment" --group Applets --group "$kickoff_applet" \
    --group Configuration --group General --key favoriteApps "$favorites_csv"
fi

if [[ -n "${icontasks_containment:-}" && -n "${icontasks_applet:-}" ]]; then
  existing_launchers="$($KREAD --file "$PLASMA_CONFIG_FILE" \
    --group Containments --group "$icontasks_containment" --group Applets --group "$icontasks_applet" \
    --group Configuration --group General --key launchers 2>/dev/null || true)"

  split_csv_to_array "$existing_launchers" taskbar_array

  for entry in "${TASKBAR_PROGRAMS[@]}"; do
    package_name="${entry%%|*}"
    desktop_file="${entry#*|}"
    launcher_entry="applications:$desktop_file"

    if ! is_package_installed "$package_name"; then
      echo "Taskbar: skipping $desktop_file ($package_name not installed)"
      continue
    fi

    if ! desktop_file_exists "$desktop_file"; then
      echo "Taskbar: skipping $desktop_file (desktop file not found)"
      continue
    fi

    if contains_exact "$launcher_entry" "${taskbar_array[@]}"; then
      echo "Taskbar: already present $desktop_file"
      continue
    fi

    taskbar_array+=("$launcher_entry")
    echo "Taskbar: added $desktop_file"
  done

  launchers_csv="$(join_array_to_csv taskbar_array)"

  "$KWRITE" --file "$PLASMA_CONFIG_FILE" \
    --group Containments --group "$icontasks_containment" --group Applets --group "$icontasks_applet" \
    --group Configuration --group General --key launchers "$launchers_csv"
fi

if command -v qdbus6 >/dev/null 2>&1; then
  qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.reloadConfig >/dev/null 2>&1 || true
elif command -v qdbus >/dev/null 2>&1; then
  qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.reloadConfig >/dev/null 2>&1 || true
fi

echo "Restarting plasmashell to apply visual changes..."
if command -v kquitapp6 >/dev/null 2>&1 && command -v kstart6 >/dev/null 2>&1; then
  kquitapp6 plasmashell >/dev/null 2>&1 || true
  sleep 1
  kstart6 plasmashell >/dev/null 2>&1 || true
elif command -v kquitapp5 >/dev/null 2>&1 && command -v kstart5 >/dev/null 2>&1; then
  kquitapp5 plasmashell >/dev/null 2>&1 || true
  sleep 1
  kstart5 plasmashell >/dev/null 2>&1 || true
fi

echo "Done updating KDE favorites and taskbar pins."
