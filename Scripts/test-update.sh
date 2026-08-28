#!/bin/bash
# The assembled app really can update itself: a loadable, correctly signed Sparkle inside the
# bundle, and the immutable half of the key that verifies every release.
#
# This suite exists because none of it fails loudly. A Sparkle signed with the wrong options, or a
# framework the app cannot find, still builds, still notarises and still installs — and then the
# first update somebody accepts goes nowhere, with no error anybody sees.
#
#   ./Scripts/test-update.sh                       checks dist/Loadout.app
#   LOADOUT_APP=/path/to/Loadout.app ./Scripts/test-update.sh

set -uo pipefail
cd "$(dirname "$0")/.."

APP="${LOADOUT_APP:-dist/Loadout.app}"
INFO="$APP/Contents/Info.plist"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
failures=0

check() {
	local name="$1"
	shift
	if "$@" >/dev/null 2>&1; then echo "OK   $name"; else failures=$((failures + 1)); echo "FAIL $name"; fi
}

check "there is an app to check" test -d "$APP"
check "Sparkle is embedded" test -f "$FRAMEWORK/Versions/B/Sparkle"
check "the installer is embedded" test -f "$FRAMEWORK/Versions/B/Autoupdate"
check "the update window is embedded" test -d "$FRAMEWORK/Versions/B/Updater.app"
check "unused sandbox services are absent" test ! -e "$FRAMEWORK/XPCServices"
check "the framework and its helpers are signed" codesign --verify --deep --strict "$FRAMEWORK"
check "the app and everything in it are signed" codesign --verify --deep --strict "$APP"
check "the app can find the embedded framework" sh -c \
	"otool -l '$APP/Contents/MacOS/Loadout' | grep -q '@loader_path/../Frameworks'"
check "the feed has one stable address" sh -c \
	"test \"\$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' '$INFO')\" = \
	'https://github.com/migsilva89/loadout/releases/latest/download/appcast.xml'"
check "updates require the public signing key" sh -c \
	"test -n \"\$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' '$INFO')\""
check "the download is verified before it is unpacked" sh -c \
	"test \"\$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' '$INFO')\" = true"
check "the feed itself must also be signed" sh -c \
	"test \"\$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' '$INFO')\" = true"
check "the automatic check is on" sh -c \
	"test \"\$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' '$INFO')\" = true"
check "it asks before replacing the app" sh -c \
	"test \"\$(/usr/libexec/PlistBuddy -c 'Print :SUAllowsAutomaticUpdates' '$INFO')\" = false"
check "no system profile is sent" sh -c \
	"test \"\$(/usr/libexec/PlistBuddy -c 'Print :SUSendProfileInfo' '$INFO')\" = false"

echo
if [ "$failures" -eq 0 ]; then echo "all good"; else echo "$failures failing"; fi
[ "$failures" -eq 0 ]
