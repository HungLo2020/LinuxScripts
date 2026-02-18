#!/usr/bin/env bash

set -euo pipefail

THEME_ID="com.matt.experiment"
THEME_NAME="Matt Experiment Theme"
THEME_DESC="Fixed KDE settings for experimentation"

# Fixed settings captured from your current system on 2026-02-17.
color_scheme="ArcDark"
icon_theme="Papirus"
widget_style="Breeze"
cursor_theme="material_dark_cursors"
cursor_size=""
plasma_style="Nordic"
window_decoration="__aurorae__svg__Utterly-Round-Dark"

ICON_DIR_USER="$HOME/.local/share/icons"
COLOR_SCHEME_DIR_USER="$HOME/.local/share/color-schemes"
PLASMA_THEME_DIR_USER="$HOME/.local/share/plasma/desktoptheme"
AURORAE_DIR_USER="$HOME/.local/share/aurorae/themes"

theme_exists_icon() {
  [[ -d "$HOME/.icons/$1" || -d "$ICON_DIR_USER/$1" || -d "/usr/share/icons/$1" ]]
}

theme_exists_color_scheme() {
  [[ -f "$COLOR_SCHEME_DIR_USER/$1.colors" || -f "/usr/share/color-schemes/$1.colors" ]]
}

theme_exists_plasma_style() {
  [[ -d "$PLASMA_THEME_DIR_USER/$1" || -d "/usr/share/plasma/desktoptheme/$1" ]]
}

theme_exists_window_decoration() {
  [[ -d "$AURORAE_DIR_USER/$1" || -d "/usr/share/aurorae/themes/$1" ]]
}

install_theme_prereqs() {
  echo "Installing theme prerequisite packages..."
  sudo apt install -y git curl ca-certificates papirus-icon-theme arc-kde arc-theme bibata-cursor-theme
}

install_material_dark_cursors() {
  if theme_exists_icon "$cursor_theme"; then
    return
  fi

  echo "Installing cursor theme $cursor_theme..."
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  git clone --depth 1 https://github.com/arun54321/Material-cursors.git "$tmp_dir/material-cursors"
  mkdir -p "$ICON_DIR_USER"
  if [[ -d "$tmp_dir/material-cursors/material" ]]; then
    rm -rf "$ICON_DIR_USER/$cursor_theme"
    cp -r "$tmp_dir/material-cursors/material" "$ICON_DIR_USER/$cursor_theme"
  fi
  rm -rf "$tmp_dir"
}

install_nordic_assets() {
  if theme_exists_color_scheme "ArcDark" && theme_exists_plasma_style "$plasma_style"; then
    return
  fi

  echo "Installing Nordic assets..."
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  git clone --depth 1 https://github.com/EliverLara/Nordic.git "$tmp_dir/nordic"

  mkdir -p "$COLOR_SCHEME_DIR_USER"
  if [[ -f "$tmp_dir/nordic/kde/colorschemes/Nordic.colors" ]]; then
    cp "$tmp_dir/nordic/kde/colorschemes/Nordic.colors" "$COLOR_SCHEME_DIR_USER/Nordic.colors"
  fi

  if [[ -d "$tmp_dir/nordic/kde/plasma/desktoptheme/Nordic" ]]; then
    mkdir -p "$PLASMA_THEME_DIR_USER"
    rm -rf "$PLASMA_THEME_DIR_USER/Nordic"
    cp -r "$tmp_dir/nordic/kde/plasma/desktoptheme/Nordic" "$PLASMA_THEME_DIR_USER/Nordic"
  fi

  rm -rf "$tmp_dir"
}

install_utterly_round_dark() {
  if theme_exists_window_decoration "Utterly-Round-Dark"; then
    return
  fi

  echo "Installing Utterly-Round-Dark window decoration..."
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  git clone --depth 1 https://github.com/HimDek/Utterly-Round-Plasma-Style.git "$tmp_dir/utterly-round"
  mkdir -p "$AURORAE_DIR_USER"
  if [[ -d "$tmp_dir/utterly-round/aurorae/dark/translucent" ]]; then
    rm -rf "$AURORAE_DIR_USER/Utterly-Round-Dark"
    cp -r "$tmp_dir/utterly-round/aurorae/dark/translucent" "$AURORAE_DIR_USER/Utterly-Round-Dark"
  fi
  rm -rf "$tmp_dir"
}

if command -v plasma-apply-lookandfeel >/dev/null 2>&1; then
  APPLY_CMD="plasma-apply-lookandfeel"
elif command -v lookandfeeltool >/dev/null 2>&1; then
  APPLY_CMD="lookandfeeltool"
else
  echo "Error: plasma-apply-lookandfeel/lookandfeeltool was not found."
  exit 1
fi

install_theme_prereqs
install_material_dark_cursors
install_nordic_assets
install_utterly_round_dark

if ! theme_exists_icon "$icon_theme"; then
  echo "Warning: icon theme '$icon_theme' was not found after install."
fi

if ! theme_exists_color_scheme "$color_scheme"; then
  echo "Warning: color scheme '$color_scheme' was not found after install."
fi

if ! theme_exists_icon "$cursor_theme"; then
  echo "Warning: cursor theme '$cursor_theme' was not found after install."
fi

if ! theme_exists_plasma_style "$plasma_style"; then
  echo "Warning: Plasma style '$plasma_style' was not found after install."
fi

if ! theme_exists_window_decoration "Utterly-Round-Dark"; then
  echo "Warning: window decoration 'Utterly-Round-Dark' was not found after install."
fi

if command -v kwriteconfig6 >/dev/null 2>&1; then
  KWRITE="kwriteconfig6"
elif command -v kwriteconfig5 >/dev/null 2>&1; then
  KWRITE="kwriteconfig5"
else
  KWRITE=""
fi

THEME_DIR="$HOME/.local/share/plasma/look-and-feel/$THEME_ID"
mkdir -p "$THEME_DIR/contents/layouts"

cat > "$THEME_DIR/metadata.json" <<EOF
{
  "KPlugin": {
    "Authors": [
      {
        "Name": "matt"
      }
    ],
    "Category": "Plasma Look And Feel",
    "Description": "$THEME_DESC",
    "EnabledByDefault": true,
    "Id": "$THEME_ID",
    "License": "CC0-1.0",
    "Name": "$THEME_NAME",
    "Version": "1.0"
  },
  "X-KDE-PluginInfo-Name": "$THEME_ID"
}
EOF

cat > "$THEME_DIR/contents/defaults" <<EOF
[kdeglobals][General]
ColorScheme=$color_scheme

[kdeglobals][Icons]
Theme=$icon_theme

[kdeglobals][KDE]
widgetStyle=$widget_style

[kcminputrc][Mouse]
cursorTheme=$cursor_theme
cursorSize=$cursor_size

[plasmarc][Theme]
name=$plasma_style

[kwinrc][org.kde.kdecoration2]
theme=$window_decoration
EOF

cat > "$THEME_DIR/contents/layouts/org.kde.plasma.desktop-layout.js" <<'EOF'
var plasma = getApiVersion(1);
var activity = plasma.activityIds[0];
var desktops = plasma.desktopsForActivity(activity);
for (var i = 0; i < desktops.length; i++) {
  desktops[i].wallpaperPlugin = "org.kde.image";
}
EOF

echo "Created custom KDE global theme package at: $THEME_DIR"

echo "Applying theme: $THEME_ID"
if [[ "$APPLY_CMD" == "plasma-apply-lookandfeel" ]]; then
  "$APPLY_CMD" -a "$THEME_ID"
else
  "$APPLY_CMD" --apply "$THEME_ID"
fi

if command -v plasma-apply-desktoptheme >/dev/null 2>&1; then
  echo "Applying Plasma style explicitly: $plasma_style"
  plasma-apply-desktoptheme "$plasma_style" || true
fi

if [[ -n "$KWRITE" ]]; then
  echo "Applying window decoration explicitly: $window_decoration"
  "$KWRITE" --file kwinrc --group org.kde.kdecoration2 --key library org.kde.kwin.aurorae
  "$KWRITE" --file kwinrc --group org.kde.kdecoration2 --key theme "$window_decoration"
fi

if command -v qdbus6 >/dev/null 2>&1; then
  qdbus6 org.kde.KWin /KWin reconfigure || true
elif command -v qdbus >/dev/null 2>&1; then
  qdbus org.kde.KWin /KWin reconfigure || true
fi

echo "Reloading plasmashell..."
if command -v kquitapp6 >/dev/null 2>&1 && command -v kstart6 >/dev/null 2>&1; then
  kquitapp6 plasmashell || true
  kstart6 plasmashell || true
elif command -v kquitapp5 >/dev/null 2>&1 && command -v kstart5 >/dev/null 2>&1; then
  kquitapp5 plasmashell || true
  kstart5 plasmashell || true
fi

echo "Done. Active theme set to $THEME_ID"
