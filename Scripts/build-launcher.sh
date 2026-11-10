#!/bin/bash
# Builds the plugin's launcher as the app bundle given, FM Starship Launcher.app, for the caller to sign.
# Steam on the Mac only opens app bundles from launch options, so the launcher is a small background app.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:?Say where the launcher goes: Scripts/build-launcher.sh \"DIR/FM Starship Launcher.app\"}"
mkdir -p "$APP/Contents/MacOS"
clang -O2 -Wall -arch arm64 -mmacosx-version-min=14.0 -o "$APP/Contents/MacOS/FM Starship Launcher" plugin/launcher.c \
    -framework CoreFoundation
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
