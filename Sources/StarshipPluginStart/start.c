// Runs when Football Manager loads the FM Starship plugin, before the game itself starts.
//
// The plugin arrives through DYLD_INSERT_LIBRARIES, set by FM's Steam launch options. Anything FM starts would
// inherit that, so the variable is cleared here and the Swift side only starts inside FM itself.
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "starship_plugin.h"

__attribute__((constructor)) static void plugin_load(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");

    char path[4096];
    uint32_t size = sizeof path;
    if (_NSGetExecutablePath(path, &size) != 0) return;
    const char *game = "/fm.app/Contents/MacOS/Football Manager 27";
    size_t length = strlen(path), suffix = strlen(game);
    if (length < suffix || strcmp(path + length - suffix, game) != 0) return;

    starship_plugin_start();
}
