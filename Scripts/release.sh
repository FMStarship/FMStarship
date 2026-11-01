#!/bin/bash
# Builds a signed, notarized "FM Starship.app" and wraps it in a notarized disk image in build/.
# Apple needs each one separately: the app so it opens offline, the image so Gatekeeper trusts the download.
#
# Once per Mac, store your notarization login in the keychain (it asks for an app-specific password):
#   xcrun notarytool store-credentials fm-starship --apple-id YOUR_APPLE_ID --team-id N2M33U7L7U
set -euo pipefail
cd "$(dirname "$0")/.."
export SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Markus Skov (N2M33U7L7U)}"
PROFILE="${NOTARY_PROFILE:-fm-starship}"

xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || {
    echo "No notarization login called $PROFILE in the keychain. See the top of this script." >&2
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

spctl -a -t exec -vv "$APP"
spctl -a -t open --context context:primary-signature -vv "$DMG"
shasum -a 256 "$DMG"
echo "Built $DMG"
