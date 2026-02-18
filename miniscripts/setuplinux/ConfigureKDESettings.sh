#!/usr/bin/env bash

set -euo pipefail

if command -v kwriteconfig6 >/dev/null 2>&1; then
  KWRITE="kwriteconfig6"
elif command -v kwriteconfig5 >/dev/null 2>&1; then
  KWRITE="kwriteconfig5"
else
  echo "Error: kwriteconfig5/6 was not found."
  exit 1
fi

echo "Applying KDE blur settings..."
"$KWRITE" --file kwinrc --group Plugins --key blurEnabled true
"$KWRITE" --file kwinrc --group Effect-blur --key BlurStrength 4
"$KWRITE" --file kwinrc --group Effect-blur --key NoiseStrength 3

echo "Applying KDE window opacity rules from current profile..."
cat > "$HOME/.config/kwinrulesrc" <<'EOF'
[250fcc1e-6860-4285-b8e5-e8f519cf3200]
Description=Window settings for NBTExplorer
clientmachine=localhost
opacityactiverule=2
opacityinactiverule=2
title=NBTExplorer
titlematch=1
types=1
wmclassmatch=1

[99ae91c3-bdb7-4d57-9901-92320bc00397]
Description=New window settings
opacityactive=27
opacityactiverule=2
wmclassmatch=1

[General]
count=3
rules=fabe94f4-5f61-4fb4-a94b-5fbf8a8e5a92,250fcc1e-6860-4285-b8e5-e8f519cf3200,99ae91c3-bdb7-4d57-9901-92320bc00397

[fabe94f4-5f61-4fb4-a94b-5fbf8a8e5a92]
Description=Window settings for Open
clientmachine=localhost
opacityactiverule=2
opacityinactiverule=2
title=Open
titlematch=1
types=1
wmclassmatch=1
EOF

echo "Reloading KWin config..."
if command -v qdbus6 >/dev/null 2>&1; then
  qdbus6 org.kde.KWin /KWin reconfigure || true
elif command -v qdbus >/dev/null 2>&1; then
  qdbus org.kde.KWin /KWin reconfigure || true
fi

echo "Done applying KDE blur/transparency-related settings."