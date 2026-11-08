#!/bin/bash
# Installs the FM Starship plugin prototype for this user and prints the Steam launch option that loads it into FM.
# Safe while FM is running: a game started with the old copy keeps it, and the next start gets the new one.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product StarshipPlugin
BIN="$(swift build -c release --show-bin-path)"

DEST="$HOME/Library/Application Support/FMStarship/Plugin"
mkdir -p "$DEST"
# Replaced rather than overwritten, so a running FM's mapped copy is never changed underneath it.
cp "$BIN/libStarshipPlugin.dylib" "$DEST/.libStarshipPlugin.dylib.new"
codesign -f -s - "$DEST/.libStarshipPlugin.dylib.new"
mv -f "$DEST/.libStarshipPlugin.dylib.new" "$DEST/libStarshipPlugin.dylib"

# Steam on the Mac only opens app bundles from launch options, so the launcher is a small background app.
APP="$DEST/FM Starship Launcher.app"
rm -rf "$APP" "$DEST/start-fm.sh"
mkdir -p "$APP/Contents/MacOS"
clang -O2 -Wall -arch arm64 -mmacosx-version-min=14.0 -o "$APP/Contents/MacOS/FM Starship Launcher" plugin/launcher.c
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FM Starship Launcher</string>
<key>CFBundleIdentifier</key><string>com.fmstarship.launcher</string>
<key>CFBundleName</key><string>FM Starship Launcher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign -f -s - "$APP"

echo "Installed in $DEST"
echo "In Steam, open Football Manager 27 > Properties > General > Launch Options and enter:"
echo "\"$APP\" %command%"
