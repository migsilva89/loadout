#!/bin/bash
# Signs one finished disk image and writes the Sparkle feed that is published beside it.
#
# The private EdDSA key stays in this machine's login keychain under the `loadout` account and is
# never written to a file here; only its public half is in the app's Info.plist, put there by
# Scripts/build-app.sh. Nothing in this script prints or exports the private key.
#
# The feed points at a second, identically-built copy of the image, published under the `-update`
# name. Same bytes, same signature, different GitHub asset — which is the only way to tell an
# update apart from a first install, because GitHub counts downloads per asset and nothing else.
# Both must be published or installed copies follow the feed to a 404.
#
#   ./Scripts/appcast.sh                          signs dist/Loadout-<version>.dmg
#   ./Scripts/appcast.sh path/to/Some.dmg         signs that one instead

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

# The same question build-app.sh asks, so the feed can never describe a version the app does not
# claim: only version tags count.
VERSION="$(git -C "$ROOT" describe --tags --match 'v[0-9]*' --always 2>/dev/null || echo "0.0.0")"
VERSION="${VERSION#v}"

DMG="${1:-$ROOT/dist/Loadout-$VERSION.dmg}"
APP="$ROOT/dist/Loadout.app"
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
GENERATE="$TOOLS/generate_appcast"
KEYS="$TOOLS/generate_keys"
OUTPUT="$ROOT/dist/appcast.xml"
UPDATE_DMG="$ROOT/dist/Loadout-$VERSION-update.dmg"

[ -f "$DMG" ] || { echo "error: no disk image at $DMG" >&2; exit 1; }
[ -x "$GENERATE" ] || {
	echo "error: Sparkle's release tools are missing — run swift package resolve" >&2
	exit 1
}

# The public key in the built app and the private key in the keychain are two halves of one thing.
# If they have drifted apart — a rebuilt key, a different machine — every installed copy would
# reject this update as forged, and it would look like the updater is broken rather than the key.
[ -f "$APP/Contents/Info.plist" ] || {
	echo "error: no built app at $APP — run Scripts/build-app.sh first" >&2
	exit 1
}
EXPECTED="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
ACTUAL="$("$KEYS" --account loadout -p)"
[ "$ACTUAL" = "$EXPECTED" ] || {
	echo "error: the Sparkle key in the keychain does not match the app" >&2
	exit 1
}

# generate_appcast reads a directory and describes everything in it, so it gets a directory holding
# exactly one image — the update copy, under the name the feed should point at.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$DMG" "$STAGE/$(basename "$UPDATE_DMG")"

"$GENERATE" \
	--account loadout \
	--download-url-prefix "https://github.com/migsilva89/loadout/releases/download/v$VERSION/" \
	--full-release-notes-url "https://github.com/migsilva89/loadout/blob/main/CHANGELOG.md" \
	--link "https://loadout.migsilva.dev" \
	--maximum-versions 1 \
	--maximum-deltas 0 \
	-o "$STAGE/appcast.xml" \
	"$STAGE"

cp "$STAGE/appcast.xml" "$OUTPUT"
cp "$DMG" "$UPDATE_DMG"

# An unsigned feed is worse than no feed: SURequireSignedFeed means installed copies would silently
# reject it, so the app would look like it had simply stopped finding updates.
xmllint --noout "$OUTPUT"
grep -q 'sparkle:edSignature=' "$OUTPUT" \
	|| { echo "error: the update in appcast.xml is not signed" >&2; exit 1; }
grep -q '<!-- sparkle-signatures:' "$OUTPUT" \
	|| { echo "error: appcast.xml itself is not signed" >&2; exit 1; }
grep -q "$(basename "$UPDATE_DMG")" "$OUTPUT" \
	|| { echo "error: the feed does not point at the update copy" >&2; exit 1; }

echo "update feed → $OUTPUT"
echo "update image → $UPDATE_DMG"
