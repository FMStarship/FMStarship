#!/bin/bash
# Installs the FM Starship plugin preview for this user and prints the Steam launch option that loads it into FM.
# Safe while FM is running: a game started with the old copy keeps it, and the next start gets the new one.
#
# --developer builds in the developer tools: the command file, Control-Option-D and the table watch. They're for
# working on the plugin, so a plain install leaves them out.
#
# --uninstall removes the plugin and its launcher.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="$HOME/Library/Application Support/FMStarship/Plugin"
FLAGS=()
case "${1:-}" in
    "") ;;
    --developer) FLAGS=(-Xswiftc -DSTARSHIP_DEVELOPER) ;;
    --uninstall)
        # Steam can't start FM while its launch option names a launcher that's gone, so that step comes first.
        echo "First clear FM's launch option: in Steam, open Football Manager 27 > Properties > General > Launch Options and"
        echo "delete what's there. Until you do, Steam can't start FM."
        rm -rf "$DEST"
        echo "Removed $DEST"
        exit 0 ;;
    *) echo "Usage: $0 [--developer | --uninstall]" >&2; exit 2 ;;
esac
# The odd expansion keeps macOS's bash 3.2 from calling an empty list unbound.
swift build -c release --product StarshipPlugin ${FLAGS[@]+"${FLAGS[@]}"}
BIN="$(swift build -c release --show-bin-path)"

mkdir -p "$DEST"
# Replaced rather than overwritten, so a running FM's mapped copy is never changed underneath it.
cp "$BIN/libStarshipPlugin.dylib" "$DEST/.libStarshipPlugin.dylib.new"
codesign -f -s - "$DEST/.libStarshipPlugin.dylib.new"
mv -f "$DEST/.libStarshipPlugin.dylib.new" "$DEST/libStarshipPlugin.dylib"

# Steam on the Mac only opens app bundles from launch options, so the launcher is a small background app.
# It's built beside the old one and moved into place, so a failed build leaves the old one starting FM.
APP="$DEST/FM Starship Launcher.app"
BUILD="$(mktemp -d "$DEST/.launcher.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
NEW="$BUILD/FM Starship Launcher.app"
Scripts/build-launcher.sh "$NEW"
codesign -f -s - "$NEW"
rm -rf "$APP" "$DEST/start-fm.sh"
mv "$NEW" "$APP"

echo "Installed in $DEST"
if [ ${#FLAGS[@]} -gt 0 ]; then echo "This is a developer build, with the command file and Control-Option-D."; fi
echo "In Steam, open Football Manager 27 > Properties > General > Launch Options and enter:"
echo "\"$APP\" %command%"
