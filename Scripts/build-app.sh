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
# Only version tags count. Without --match, any tag in the repository becomes the app's version —
# a tag left behind before a history rewrite once turned up as the version string in Get Info.
VERSION="$(git -C "$ROOT" describe --tags --match 'v[0-9]*' --always 2>/dev/null || echo "0.0.0")"
VERSION="${VERSION#v}"

# Ad hoc unless told otherwise. A Developer ID signature is what lets the app open on a machine
# other than this one, and `--options runtime` — the hardened runtime — is what Apple requires
# before it will notarise anything.
SIGN_IDENTITY="${LOADOUT_SIGN_IDENTITY:-}"

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
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Miguel Silva</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" > /dev/null

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "→ A assinar com Developer ID"
  # No --deep: it is deprecated and signs nested code with the wrong options. There is nothing
  # nested here anyway — one binary in one bundle.
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
  codesign --verify --strict --verbose=1 "$APP" 2>&1 | tail -1
else
  echo "→ A assinar (ad hoc — só corre nesta máquina)"
  codesign --force --sign - "$APP" 2>/dev/null
fi

# Make sure Finder and the Dock pick the new icon up rather than a cached one.
touch "$APP"

echo "✓ $APP"
