#!/bin/bash
# Builds a signed, notarized "FM Starship.app" and wraps it in a notarized disk image in build/.
# Apple needs each one separately: the app so it opens offline, the image so Gatekeeper trusts the download.
#
# Once per Mac, store your notarization login in the keychain (it asks for an app-specific password):
#   xcrun notarytool store-credentials fm-starship --apple-id YOUR_APPLE_ID --team-id N2M33U7L7U
#
# It also writes build/appcast.xml, the update feed, which is published with the disk image. The app only accepts
# updates signed with the private half of UPDATE_PUBLIC_KEY, which lives in the login keychain. Keep a copy somewhere
# safe (generate_keys -x FILE), because without it nobody gets another update through the app. On a new Mac, bring it
# in with generate_keys -f FILE. Both are in .build/artifacts/sparkle/Sparkle/bin.
#
# Usage: Scripts/release.sh NOTES.md
# The notes are what the update window shows, so say what changed. Markdown works.
set -euo pipefail
cd "$(dirname "$0")/.."
NOTES="${1:?Say which file has the release notes: Scripts/release.sh NOTES.md}"
export SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Markus Skov (N2M33U7L7U)}"
export UPDATE_PUBLIC_KEY="${UPDATE_PUBLIC_KEY:-/loC6O9XkDodo3V+lpKBHQ43OUvuP67wp0jILhHpw2I=}"
PROFILE="${NOTARY_PROFILE:-fm-starship}"
TOOLS=.build/artifacts/sparkle/Sparkle/bin

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || {
    echo "No notarization login called $PROFILE in the keychain. See the top of this script." >&2
    exit 1
}
swift package resolve
[ -n "$UPDATE_PUBLIC_KEY" ] && [ "$("$TOOLS/generate_keys" -p 2>/dev/null)" = "$UPDATE_PUBLIC_KEY" ] || {
    echo "The update signing key in the keychain isn't UPDATE_PUBLIC_KEY, so the app would refuse this update. See the top of this script." >&2
    exit 1
}

Scripts/build-app.sh
APP="build/FM Starship.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/FM-Starship-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto -c -k --keepParent "$APP" "$STAGE/app.zip"
xcrun notarytool submit "$STAGE/app.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

mkdir "$STAGE/image"
ditto "$APP" "$STAGE/image/FM Starship.app"
ln -s /Applications "$STAGE/image/Applications"
rm -f "$DMG"
hdiutil create -volname "FM Starship" -srcfolder "$STAGE/image" -format UDZO -ov "$DMG"
codesign -f -s "$SIGN_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# After stapling, because that changes the disk image the feed signs.
mkdir "$STAGE/feed"
cp "$DMG" "$STAGE/feed/"
cp "$NOTES" "$STAGE/feed/$(basename "$DMG" .dmg).md"
"$TOOLS/generate_appcast" --maximum-deltas 0 --embed-release-notes \
    --download-url-prefix "https://github.com/FMStarship/FMStarship/releases/download/v$VERSION/" "$STAGE/feed"
cp "$STAGE/feed/appcast.xml" build/appcast.xml

spctl -a -t exec -vv "$APP"
spctl -a -t open --context context:primary-signature -vv "$DMG"
shasum -a 256 "$DMG"
echo "Built $DMG and build/appcast.xml"
