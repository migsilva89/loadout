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

echo "→ Building ($CONFIG)"
swift build -c "$CONFIG" --product LoadoutApp

BINARY="$(swift build -c "$CONFIG" --product LoadoutApp --show-bin-path)/LoadoutApp"
[[ -x "$BINARY" ]] || { echo "no binary at $BINARY"; exit 1; }

echo "→ Assembling the bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BINARY" "$APP/Contents/MacOS/Loadout"

# Sparkle is what installs the next version, so it travels inside the app. `ditto` rather than
# `cp -R` because a framework is a bundle of symlinks and cp flattens them, which produces a
# framework that looks right and will not load.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
BUILT_SPARKLE="$(dirname "$BINARY")/Sparkle.framework"
[[ -d "$BUILT_SPARKLE" ]] || { echo "no Sparkle.framework beside $BINARY — run 'swift package resolve'"; exit 1; }
rm -rf "$SPARKLE"
ditto "$BUILT_SPARKLE" "$SPARKLE"
# Loadout is not sandboxed. Sparkle's XPC services exist only to carry the installer across a
# sandbox boundary, so keeping them ships two executables and two signatures that can never run.
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"

if [[ -f "$ROOT/Resources/Loadout.icns" ]]; then
  cp "$ROOT/Resources/Loadout.icns" "$APP/Contents/Resources/Loadout.icns"
else
  echo "  (no icon: run 'swift Scripts/make-icon.swift' first)"
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

    <!-- Sparkle. Loadout updates itself: it downloads the new version and replaces this copy.
         The feed lives on the "latest" release, which is one address that never changes as
         versions come and go. SUPublicEDKey is the public half of the key the release is signed
         with — its private half is in this machine's login keychain under the account "loadout"
         and is not in this repository. An update that is not signed with it is refused, which is
         what stops a man in the middle handing the app a different Loadout.

         SUAllowsAutomaticUpdates is false on purpose: Loadout asks before it replaces itself.
         Installing silently under somebody working in the app is not a decision to take for them. -->
    <key>SUFeedURL</key><string>https://github.com/migsilva89/loadout/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>lUaE3YVkBVqKzXHSQ5Kuex3WtTnffdZtNfHTFbA85ts=</string>
    <key>SURequireSignedFeed</key><true/>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAllowsAutomaticUpdates</key><false/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SUSendProfileInfo</key><false/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" > /dev/null

# Inside out, and never with --deep. --deep is deprecated and applies the outer bundle's options
# to nested code, which is exactly wrong here: Autoupdate and Updater.app are separate programs
# that must each carry their own signature and the hardened runtime. Signing the app first and the
# framework after would also be pointless — changing anything inside a bundle invalidates the
# signature wrapped around it.
#
# This is the part that fails quietly. A wrongly signed Sparkle still notarises and still ships;
# it only breaks when somebody accepts an update, and then the installer cannot launch and the app
# just never updates. Scripts/test-update.sh checks the assembled bundle for that.
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "→ Signing with Developer ID"
  SIGN=("$SIGN_IDENTITY" --options runtime --timestamp)
else
  echo "→ Signing (ad hoc — only runs on this machine)"
  # No hardened runtime and no timestamp: an ad hoc signature cannot carry either, and asking for
  # them makes codesign refuse rather than warn.
  SIGN=(- --timestamp=none)
fi

codesign --force --sign "${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate" 2>/dev/null
codesign --force --sign "${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app" 2>/dev/null
codesign --force --sign "${SIGN[@]}" "$SPARKLE" 2>/dev/null
codesign --force --sign "${SIGN[@]}" "$APP" 2>/dev/null
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | tail -1

# Make sure Finder and the Dock pick the new icon up rather than a cached one.
touch "$APP"

echo "✓ $APP"
