#!/bin/bash
# Builds dist/Loadout-<version>.dmg — the one build somebody else installs by dragging.
#
#   ./Scripts/release.sh                       ad hoc: only opens on this machine
#   LOADOUT_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./Scripts/release.sh
#                                              signed, ready to notarise
#   LOADOUT_NOTARY_PROFILE=loadout ./Scripts/release.sh
#                                              signed, notarised, stapled — opens anywhere
#
# The notary profile holds an Apple ID, a team id and an app-specific password, and is stored once
# in the keychain, never in this repository:
#
#   xcrun notarytool store-credentials loadout \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific>
#
# Generate the app-specific password at appleid.apple.com › Sign-In and Security. It is not the
# account password, and it never appears in a file here.
#
# Pass --force to skip the checks. Do that knowing what you are skipping.
#
# A full run writes three files that are published together: the disk image, an identical copy
# named Loadout-<version>-update.dmg, and the signed appcast.xml that points installed copies at
# it. Loadout updates itself from that feed, so leaving any of the three out breaks the updater
# for everybody who already has the app.

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

SIGN_IDENTITY="${LOADOUT_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${LOADOUT_NOTARY_PROFILE:-}"

APP="$ROOT/dist/Loadout.app"
STAGE="$ROOT/dist/dmg"

step() { printf '\n\033[1;35m▸ %s\033[0m\n' "$1"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ------------------------------------------------------------------------ checks
#
# A release is the build that leaves this machine, so it must come from a commit somebody can go
# back to — and it must pass its own tests. A signed, notarised, broken build is worse than an
# unsigned one: it carries a name and opens without a single warning.

if [ "${1:-}" != "--force" ]; then
	step "checks"

	[ -z "$(git status --porcelain)" ] \
		|| die "uncommitted changes — a release has to be a commit somebody can go back to"

	BRANCH="$(git rev-parse --abbrev-ref HEAD)"
	[ "$BRANCH" = "main" ] || die "on $BRANCH, not main"

	git fetch --quiet origin main 2>/dev/null || true
	if git rev-parse --quiet --verify origin/main >/dev/null; then
		[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
			|| die "main and origin/main have diverged — push or pull first"
	fi

	git describe --tags --match 'v[0-9]*' --exact-match >/dev/null 2>&1 \
		|| die "this commit has no version tag — 'git tag v0.1.0' first, or the build has no version"

	swift test >/dev/null 2>&1 || die "the tests failed"
	echo "clean tree, on main, in sync, tagged, tests pass"
fi

VERSION="$(git describe --tags --match 'v[0-9]*' --always)"
VERSION="${VERSION#v}"
DMG="$ROOT/dist/Loadout-$VERSION.dmg"
APPCAST="$ROOT/dist/appcast.xml"
UPDATE_DMG="$ROOT/dist/Loadout-$VERSION-update.dmg"

# ------------------------------------------------------------------------- build

step "build"
LOADOUT_SIGN_IDENTITY="$SIGN_IDENTITY" ./Scripts/build-app.sh

if [ "${1:-}" != "--force" ]; then
	step "self-check"
	# Against the binary that was just built, rather than whatever sits in .build from yesterday.
	"$APP/Contents/MacOS/Loadout" --self-check >/dev/null || die "the self-check failed"
	# And against the assembled bundle: whether Sparkle is embedded, signed and pointed at the
	# right feed cannot be answered by swift test, because none of it exists until the app is put
	# together. A wrongly signed Sparkle notarises happily and only fails months later, on the
	# first update somebody accepts.
	LOADOUT_APP="$APP" ./Scripts/test-update.sh >/dev/null 2>&1 \
		|| die "the update bundle checks failed — run ./Scripts/test-update.sh to see which"
	echo "self-check ok, update bundle ok"
fi

# --------------------------------------------------------------------------- dmg

step "disk image"
rm -rf "$STAGE" "$DMG"
# Last release's feed and update copy, gone before this one is built. Left in place, a build that
# stops short of notarising would leave dist/ looking like a complete release describing the
# previous version — and publishing that points every installed copy at the wrong download.
rm -f "$APPCAST"
rm -f "$ROOT"/dist/Loadout-*-update.dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# The symlink is the whole installer: drag the app onto it and it is installed.
ln -s /Applications "$STAGE/Applications"

hdiutil create \
	-volname "Loadout $VERSION" \
	-srcfolder "$STAGE" \
	-ov -format UDZO \
	"$DMG" >/dev/null
rm -rf "$STAGE"

# ---------------------------------------------------------------------- notarise

if [ -z "$SIGN_IDENTITY" ]; then
	echo
	echo "warning: no LOADOUT_SIGN_IDENTITY, so this image is ad hoc." >&2
	echo "         It installs here and nowhere else — macOS refuses it on another Mac." >&2
elif [ -z "$NOTARY_PROFILE" ]; then
	step "sign the image"
	codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
	echo
	echo "warning: signed but not notarised. Without Apple's stamp, Gatekeeper still" >&2
	echo "         warns on somebody else's machine. Set LOADOUT_NOTARY_PROFILE." >&2
else
	step "sign the image"
	codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

	# --wait blocks for the verdict rather than handing back a ticket to chase, and stapling puts
	# that verdict inside the image, so it opens on a machine with no network.
	step "notarise (this takes a while — Apple is looking at it)"
	xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
	xcrun stapler staple "$DMG"
	xcrun stapler validate "$DMG"

	# After stapling, never before: the feed signs the bytes of the finished image, and stapling
	# changes them. A feed made from the unstapled image describes a download nobody will get.
	step "update feed"
	./Scripts/appcast.sh "$DMG"
fi

step "done"
printf '\033[1;32m✓ %s (%s)\033[0m\n' "$DMG" "$(du -h "$DMG" | cut -f1)"

# Publishing is the last manual step, and it is the one that can quietly break every installed
# copy. Three files go up together or none do: the image people download by hand, the identical
# `-update` copy the feed points at, and the signed feed itself. Publish the image alone and the
# updater 404s; publish an unsigned feed and every app refuses it, because SURequireSignedFeed
# means an unverified feed is treated as no feed at all.
if [ -f "$APPCAST" ] \
	&& grep -q 'sparkle:edSignature=' "$APPCAST" \
	&& grep -q '<!-- sparkle-signatures:' "$APPCAST"; then
	cat <<-EOF

	then, to publish:
	  gh release create v$VERSION "$DMG" "$UPDATE_DMG" "$APPCAST" \
	    --title "Loadout $VERSION" --notes "…"

	$(basename "$UPDATE_DMG") is the same image under a second name: the feed points installed
	copies at it, so GitHub's per-asset counter separates updates from first installs. Publish
	all three or the updater breaks.
	EOF
else
	cat <<-EOF

	warning: there is no signed update feed in dist/, so this build must not be published as a
	release — installed copies would keep following the previous version's feed, or reject an
	unsigned one and stop finding updates at all. Only a signed and notarised run writes
	$APPCAST. This build is for local testing.
	EOF
fi
