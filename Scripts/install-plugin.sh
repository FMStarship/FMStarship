#!/bin/bash
# Installs the FM Starship plugin preview for this user and prints the Steam launch option that loads it into FM.
# Safe while FM is running: a game started with the old copy keeps it, and the next start gets the new one.
#
# --developer builds in the developer tools: the command file, Control-Option-D and the table watch. They're for
# working on the plugin, so a plain install leaves them out.
#
# --plugin-only rebuilds and replaces only the plugin and leaves the launcher as it is, for quick tuning rounds. It goes with
# --developer, and needs an earlier full install, which made the launcher.
#
# --uninstall removes the plugin, its marker and FM's table files, and keeps the launcher, as the app's Remove does, so Steam
# still starts FM, without FM Starship, if the launch option is left in. --uninstall-all removes the whole folder, launcher
# included: clear the launch option first.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="$HOME/Library/Application Support/FMStarship/Plugin"
FLAGS=()
PLUGIN_ONLY=0
UNINSTALL=""
usage() { echo "Usage: $0 [--developer] [--plugin-only] | --uninstall | --uninstall-all" >&2; exit 2; }
for ARG in "$@"; do
    case "$ARG" in
        --developer) FLAGS=(-Xswiftc -DSTARSHIP_DEVELOPER) ;;
        --plugin-only) PLUGIN_ONLY=1 ;;
        --uninstall | --uninstall-all) UNINSTALL="$ARG" ;;
        *) usage ;;
    esac
done
if [ -n "$UNINSTALL" ]; then
    # Nothing else goes with an uninstall.
    if [ $# -ne 1 ]; then usage; fi
    # The plugin goes first, so a removal that stops partway never leaves the plugin without its marker.
    rm -f "$DEST/libStarshipPlugin.dylib" "$DEST/installed-by-app.json" "$DEST/fm-table-assets.json" "$DEST/fm-staff-table-assets.json"
    if [ "$UNINSTALL" = "--uninstall-all" ]; then
        # Steam can't start FM while its launch option names a launcher that's gone, so that step comes first.
        echo "First clear FM's launch option: in Steam, open Football Manager 27 > Properties > General > Launch Options and"
        echo "delete what's there. Until you do, Steam can't start FM."
        rm -rf "$DEST"
        echo "Removed $DEST"
    else
        echo "Removed the plugin from $DEST and kept the launcher, so Steam still starts FM, without FM Starship."
        echo "Clear FM's launch option in Steam when you're done with it; \"$0 --uninstall-all\" removes the launcher too,"
        echo "once the launch option is cleared."
    fi
    exit 0
fi
APP="$DEST/FM Starship Launcher.app"
if [ "$PLUGIN_ONLY" -eq 1 ] && [ ! -d "$APP" ]; then
    echo "No launcher in $DEST yet: run $0 without --plugin-only once first." >&2
    exit 1
fi
# The odd expansion keeps macOS's bash 3.2 from calling an empty list unbound.
swift build -c release --product StarshipPlugin ${FLAGS[@]+"${FLAGS[@]}"}
BIN="$(swift build -c release --show-bin-path)"

mkdir -p "$DEST"
# The app refreshes the copies it added itself, which its marker says. This is a developer's own build, so the marker
# goes before anything is replaced, and the app leaves the folder alone from then on.
rm -f "$DEST/installed-by-app.json"
# Replaced rather than overwritten, so a running FM's mapped copy is never changed underneath it.
cp "$BIN/libStarshipPlugin.dylib" "$DEST/.libStarshipPlugin.dylib.new"
codesign -f -s - "$DEST/.libStarshipPlugin.dylib.new"
mv -f "$DEST/.libStarshipPlugin.dylib.new" "$DEST/libStarshipPlugin.dylib"

if [ "$PLUGIN_ONLY" -eq 1 ]; then
    echo "Replaced the plugin in $DEST and left the launcher as it is."
    if [ ${#FLAGS[@]} -gt 0 ]; then echo "This is a developer build, with the command file and Control-Option-D."; fi
    exit 0
fi

# Steam on the Mac only opens app bundles from launch options, so the launcher is a small background app.
# It's built beside the old one and moved into place, so a failed build leaves the old one starting FM.
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
