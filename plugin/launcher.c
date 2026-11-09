// Steam starts this in place of FM, through FM's launch options, and it starts FM with FM Starship inside it.
// Steam on the Mac only opens app bundles from launch options, so this is a small app rather than a script.
// It waits for FM to quit, so Steam still sees the game as running.
#include <errno.h>
#include <limits.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

extern char **environ;

int main(int argc, char **argv) {
    if (argc < 2) return 1;

    // %command% is the path to fm.app.
    char game[PATH_MAX];
    size_t length = strlen(argv[1]);
    if (length > 4 && strcmp(argv[1] + length - 4, ".app") == 0)
        snprintf(game, sizeof game, "%s/Contents/MacOS/Football Manager 27", argv[1]);
    else
        snprintf(game, sizeof game, "%s", argv[1]);

    // Steam's overlay may already be in the list, so the plugin goes in front of it.
    const char *home = getenv("HOME");
    char plugin[PATH_MAX], libraries[2 * PATH_MAX];
    snprintf(plugin, sizeof plugin, "%s/Library/Application Support/FMStarship/Plugin/libStarshipPlugin.dylib", home ? home : "");
    const char *existing = getenv("DYLD_INSERT_LIBRARIES");
    if (existing && *existing)
        snprintf(libraries, sizeof libraries, "%s:%s", plugin, existing);
    else
        snprintf(libraries, sizeof libraries, "%s", plugin);
    setenv("DYLD_INSERT_LIBRARIES", libraries, 1);
    // Without these the Steam API restarts FM through Steam, which would lose the plugin.
    setenv("SteamAppId", "4530370", 0);
    setenv("SteamGameId", "4530370", 0);

    argv[1] = game;
    pid_t pid;
    if (posix_spawn(&pid, game, NULL, NULL, argv + 1, environ) != 0) return 1;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
