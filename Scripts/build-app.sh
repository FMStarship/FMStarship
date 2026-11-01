#!/bin/bash
# Builds "FM Starship.app": the release binary, Info.plist and the agent that FM loads at launch.
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/build-agent.sh
swift build -c release --product FMStarship
BIN="$(swift build -c release --show-bin-path)"
APP="build/FM Starship.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/FMStarship" "$APP/Contents/MacOS/FMStarship"
cp build/libStarshipAgent.dylib Assets/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FMStarship</string>
<key>CFBundleIdentifier</key><string>com.fmstarship.mac</string>
<key>CFBundleName</key><string>FM Starship</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDisplayName</key><string>FM Starship</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>27.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDocumentTypes</key><array>
<dict><key>CFBundleTypeName</key><string>FM Starship snapshot</string><key>CFBundleTypeExtensions</key><array><string>fmasnap</string></array><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Owner</string></dict>
<dict><key>CFBundleTypeName</key><string>FM shortlist</string><key>CFBundleTypeExtensions</key><array><string>fmf</string></array><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string></dict>
</array>
</dict></plist>
PLIST
# Ad-hoc by default. With SIGN_IDENTITY set, this is what notarization wants: hardened runtime and a secure timestamp.
if [ -n "${SIGN_IDENTITY:-}" ]; then
    SIGN=(-f -s "$SIGN_IDENTITY" --options runtime --timestamp)
else
    SIGN=(-f -s -)
fi
codesign "${SIGN[@]}" "$APP/Contents/Resources/libStarshipAgent.dylib"
codesign "${SIGN[@]}" "$APP"
echo "Built $APP"
