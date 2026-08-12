#!/bin/bash
# Builds dist/Loadout.app — a double-clickable bundle around the SwiftPM executable.
#
#   ./Scripts/build-app.sh            release build
#   ./Scripts/build-app.sh --debug    faster build, for iterating
#
# The app is signed ad hoc: it runs on this machine without a Developer ID.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="release"
[[ "${1:-}" == "--debug" ]] && CONFIG="debug"

APP="$ROOT/dist/Loadout.app"
VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo "1.0")"

echo "→ A compilar ($CONFIG)"
swift build -c "$CONFIG" --product LoadoutApp

BINARY="$(swift build -c "$CONFIG" --product LoadoutApp --show-bin-path)/LoadoutApp"
[[ -x "$BINARY" ]] || { echo "não encontrei o binário em $BINARY"; exit 1; }

echo "→ A montar o bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Loadout"

if [[ -f "$ROOT/Resources/Loadout.icns" ]]; then
  cp "$ROOT/Resources/Loadout.icns" "$APP/Contents/Resources/Loadout.icns"
else
  echo "  (sem ícone: corre 'swift Scripts/make-icon.swift' primeiro)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Loadout</string>
    <key>CFBundleDisplayName</key><string>Loadout</string>
    <key>CFBundleIdentifier</key><string>com.migsilva.loadout</string>
    <key>CFBundleExecutable</key><string>Loadout</string>
    <key>CFBundleIconFile</key><string>Loadout</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Miguel Silva</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" > /dev/null

echo "→ A assinar"
codesign --force --deep --sign - "$APP" 2>/dev/null

# Make sure Finder and the Dock pick the new icon up rather than a cached one.
touch "$APP"

echo "✓ $APP"
