// Runs when Football Manager loads the FM Starship plugin, before the game itself starts.
//
// The plugin arrives through DYLD_INSERT_LIBRARIES, set by FM's Steam launch options. Anything FM starts would
// inherit that, so the variable is cleared here and the Swift side only starts inside FM itself.
#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "starship_plugin.h"

// FM is known by its bundle identifier, not its path, so a patch that renames fm.app or its executable doesn't keep
// the plugin out. GameProcess.isGameExecutable in StarshipCore follows the same rule.
#define GAME_IDENTIFIER "com.SportsInteractive.FootballManager27"

// The bundle's Info.plist, read as a file rather than through CFBundle, which would leave FM's bundle in CF's caches.
static CFDictionaryRef read_info(const char *path) {
    int file = open(path, O_RDONLY | O_CLOEXEC);
    if (file < 0) return NULL;
    CFPropertyListRef info = NULL;
    struct stat about;
    if (fstat(file, &about) == 0 && about.st_size > 0 && about.st_size <= 1 << 20) {
        UInt8 *bytes = malloc((size_t)about.st_size);
        if (bytes && read(file, bytes, (size_t)about.st_size) == about.st_size) {
            CFDataRef data = CFDataCreate(NULL, bytes, (CFIndex)about.st_size);
            if (data) {
                info = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
                CFRelease(data);
            }
        }
        free(bytes);
    }
    close(file);
    if (info && CFGetTypeID(info) != CFDictionaryGetTypeID()) {
        CFRelease(info);
        info = NULL;
    }
    return (CFDictionaryRef)info;
}

static bool same_file(const char *one, const char *other) {
    struct stat first, second;
    return stat(one, &first) == 0 && stat(other, &second) == 0 && first.st_dev == second.st_dev && first.st_ino == second.st_ino;
}

// True when `executable` is FM itself: BUNDLE/Contents/MacOS/NAME, where BUNDLE's Info.plist has FM's identifier and
// names that file as its executable. Steam, the launcher and any helper FM keeps in its bundle aren't.
bool starship_plugin_is_game(const char *executable) {
    char path[PATH_MAX];
    if (!executable || !realpath(executable, path)) return false;
    static const char inside[] = "/Contents/MacOS";
    size_t length = sizeof inside - 1;
    char *name = strrchr(path, '/');
    size_t folder = name ? (size_t)(name - path) : 0;
    if (folder < length || memcmp(name - length, inside, length) != 0) return false;

    char info_path[PATH_MAX];
    int written = snprintf(info_path, sizeof info_path, "%.*s/Contents/Info.plist", (int)(folder - length), path);
    if (written < 0 || written >= (int)sizeof info_path) return false;
    CFDictionaryRef info = read_info(info_path);
    if (!info) return false;

    bool game = false;
    CFTypeRef identifier = CFDictionaryGetValue(info, kCFBundleIdentifierKey);
    CFTypeRef named = CFDictionaryGetValue(info, kCFBundleExecutableKey);
    if (identifier && CFGetTypeID(identifier) == CFStringGetTypeID() && CFEqual(identifier, CFSTR(GAME_IDENTIFIER))
        && named && CFGetTypeID(named) == CFStringGetTypeID()) {
        // Compared as files, so a name's case or Unicode form in Info.plist doesn't matter.
        char expected[PATH_MAX];
        int prefix = snprintf(expected, sizeof expected, "%.*s/", (int)folder, path);
        game = prefix > 0 && prefix < (int)sizeof expected
            && CFStringGetFileSystemRepresentation(named, expected + prefix, (CFIndex)(sizeof expected - (size_t)prefix))
            && expected[prefix] && same_file(path, expected);
    }
    CFRelease(info);
    return game;
}

// FM's bundle: BUNDLE in BUNDLE/Contents/MacOS/NAME, from the executable's real path, the shape starship_plugin_is_game
// has already checked. The Swift side reads FM's build from it, so it never asks CFBundle before FM's main().
static bool game_bundle(const char *executable, char bundle[PATH_MAX]) {
    if (!realpath(executable, bundle)) return false;
    static const char inside[] = "/Contents/MacOS";
    size_t length = sizeof inside - 1;
    char *name = strrchr(bundle, '/');
    if (!name || (size_t)(name - bundle) < length || memcmp(name - length, inside, length) != 0) return false;
    *(name - length) = '\0';
    return true;
}

__attribute__((constructor)) static void plugin_load(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");

    char path[4096];
    uint32_t size = sizeof path;
    if (_NSGetExecutablePath(path, &size) != 0 || !starship_plugin_is_game(path)) return;

    char bundle[PATH_MAX];
    starship_plugin_start(game_bundle(path, bundle) ? bundle : NULL);
}
