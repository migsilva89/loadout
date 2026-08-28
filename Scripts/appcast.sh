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

# Sparkle's dialog says only that a new version is available unless the feed carries a description
# of its own, and the tooling has exactly one way to be given one: a file beside the archive in the
# directory it scans, named after that archive — Loadout-<version>-update.html next to
# Loadout-<version>-update.dmg. HTML with no DOCTYPE or body tags is embedded in the feed rather
# than linked, which is what the dialog needs, because at that moment it is being read by somebody
# deciding whether to press Install and it cannot go and fetch anything.
NOTES="$STAGE/$(basename "${UPDATE_DMG%.dmg}").html"

# This version's section and no other: from its own '## <version>' heading to the next one. A
# dialog describing the previous release's work is worse than one describing none, because it is
# believed.
SECTION="$(awk -v v="$VERSION" '
	$1 == "##" && $2 == v { inside = 1; next }
	$1 == "##" && inside  { exit }
	inside                { print }
' "$ROOT/CHANGELOG.md")"

[ -n "$(printf '%s' "$SECTION" | tr -d '[:space:]')" ] || {
	echo "error: CHANGELOG.md has nothing under '## $VERSION' — the update dialog would announce" >&2
	echo "       this version and then show the reader nothing about it" >&2
	exit 1
}

# Only what this changelog actually writes: '### Fixed'-style subheadings, '- ' bullets whose text
# wraps across lines and sometimes carries a second paragraph, **bold**, `code` and [text](url).
# Every line is escaped on the way in — one stray & or < in a release note would make the signed
# feed invalid XML, and installed copies would reject the whole thing rather than one item.
#
# Colours are left to the reader's system: Sparkle draws this in a small web view that follows dark
# mode, so a hardcoded black on white becomes unreadable the moment the Mac is dark. 'color-scheme'
# tells WebKit to pick both, and the one tint used here is a grey that works either way.
{
	cat <<-'CSS'
		<style>
		:root { color-scheme: light dark }
		body {
			font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
			font-size: 13px;
			line-height: 1.5;
			margin: 0;
			padding: 2px 4px;
		}
		h2 {
			font-size: 11px;
			font-weight: 600;
			letter-spacing: .05em;
			text-transform: uppercase;
			opacity: .55;
			margin: 16px 0 7px;
		}
		h2:first-child { margin-top: 0 }
		ul { margin: 0; padding-left: 17px }
		li { margin-bottom: 11px }
		li:last-child { margin-bottom: 0 }
		p { margin: 0 0 7px }
		p:last-child { margin-bottom: 0 }
		li p + p { margin-top: 7px }
		code {
			font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
			font-size: 12px;
			background: rgba(127, 127, 127, .18);
			border-radius: 3px;
			padding: 0 3px;
		}
		strong { font-weight: 600 }
		</style>
	CSS

	printf '%s\n' "$SECTION" | awk '
		function esc(s) {
			gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
			return s
		}
		function add(t)  { buf = (buf == "" ? t : buf " " t) }
		function para()  { if (buf != "") { print "<p>" buf "</p>"; buf = "" } }
		function item()  { para(); if (li) { print "</li>"; li = 0 } }
		function list()  { item(); if (ul) { print "</ul>"; ul = 0 } }

		/^### /    { list(); print "<h2>" esc(substr($0, 5)) "</h2>"; next }
		/^- /      { item(); if (!ul) { print "<ul>"; ul = 1 }
		             print "<li>"; li = 1; add(esc(substr($0, 3))); next }
		/^[ \t]*$/ { para(); next }
		/^  +[^ ]/ { line = $0; sub(/^ +/, "", line); add(esc(line)); next }
		           { if (ul) list(); add(esc($0)) }
		END        { list() }
	' | sed -E \
		-e 's/\[([^]]+)\]\(([^)]+)\)/<a href="\2">\1<\/a>/g' \
		-e 's/\*\*([^*]+)\*\*/<strong>\1<\/strong>/g' \
		-e 's/`([^`]+)`/<code>\1<\/code>/g'
} >"$NOTES"

# A section that is only a heading, or that the conversion emptied, would leave the same blank
# dialog as no section at all — and would do it quietly, which is the failure being fixed here.
grep -qE '<(li|p|h2)>' "$NOTES" || {
	echo "error: the '## $VERSION' section of CHANGELOG.md converted to nothing readable" >&2
	exit 1
}

"$GENERATE" \
	--account loadout \
	--download-url-prefix "https://github.com/migsilva89/loadout/releases/download/v$VERSION/" \
	--full-release-notes-url "https://github.com/migsilva89/loadout/blob/main/CHANGELOG.md" \
	--link "https://loadout.migsilva.dev" \
	--embed-release-notes \
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
grep -q '<description>' "$OUTPUT" \
	|| { echo "error: the release notes did not reach the feed — the dialog would say nothing" >&2; exit 1; }

echo "update feed → $OUTPUT"
echo "update image → $UPDATE_DMG"
