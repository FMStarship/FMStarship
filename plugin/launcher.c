// Steam starts this in place of FM, through FM's launch options, and it starts FM with FM Starship inside it.
// Steam on the Mac only opens app bundles from launch options, so this is a small app rather than a script.
// It waits for FM to quit, so Steam still sees the game as running.
// Whatever goes wrong, FM should still start: without the plugin if need be, saying why.
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

// Steam shows neither stderr nor a reason FM didn't start, so each problem also goes in the plugin's own log.
static void say(const char *format, ...) {
    char line[4 * PATH_MAX];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(line, sizeof line, format, arguments);
    va_end(arguments);
    fprintf(stderr, "FM Starship Launcher: %s\n", line);

    const char *home = getenv("HOME");
    if (!home || !*home) return;
    char path[PATH_MAX];
    if (snprintf(path, sizeof path, "%s/Library/Logs/FM Starship/plugin.log", home) >= (int)sizeof path) return;
    // Makes each missing folder on the way, as the plugin does.
    for (char *slash = path + strlen(home) + 1; (slash = strchr(slash, '/')) != NULL; slash++) {
        *slash = '\0';
        mkdir(path, 0755);
        *slash = '/';
    }
    int log = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (log < 0) return;
    char stamp[32];
    time_t now = time(NULL);
    struct tm utc;
    strftime(stamp, sizeof stamp, "%Y-%m-%dT%H:%M:%SZ", gmtime_r(&now, &utc));
    dprintf(log, "%s Launcher: %s\n", stamp, line);
    close(log);
}

// The executable's name from the bundle's Info.plist, so a renamed one still starts. Today's name if that can't be read.
static void executable(const char *bundle, char *name, size_t size) {
    const char *fallback = "Football Manager 27";
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bundle, (CFIndex)strlen(bundle), true);
    CFBundleRef app = url ? CFBundleCreate(NULL, url) : NULL;
    CFTypeRef value = app ? CFBundleGetValueForInfoDictionaryKey(app, kCFBundleExecutableKey) : NULL;
    if (!value || CFGetTypeID(value) != CFStringGetTypeID() || !CFStringGetFileSystemRepresentation(value, name, (CFIndex)size)
        || !*name) {
        say("No CFBundleExecutable in %s/Contents/Info.plist, so trying \"%s\"", bundle, fallback);
        snprintf(name, size, "%s", fallback);
    }
    if (app) CFRelease(app);
    if (url) CFRelease(url);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        say("Steam gave no game to start. FM's launch option needs %%command%% after the launcher.");
        return 1;
    }

    // %command% is the path to fm.app, perhaps with a slash on the end.
    char bundle[PATH_MAX], game[PATH_MAX];
    snprintf(bundle, sizeof bundle, "%s", argv[1]);
    size_t length = strlen(bundle);
    while (length > 1 && bundle[length - 1] == '/') bundle[--length] = '\0';
    if (length > 4 && strcmp(bundle + length - 4, ".app") == 0) {
        char name[NAME_MAX + 1];
        executable(bundle, name, sizeof name);
        snprintf(game, sizeof game, "%s/Contents/MacOS/%s", bundle, name);
    } else
        snprintf(game, sizeof game, "%s", argv[1]);

    // dyld ends a process whose inserted library can't be loaded, so the plugin only goes in if it's there.
    // Steam's overlay may already be in the list, so the plugin goes in front of it.
    const char *home = getenv("HOME");
    char plugin[PATH_MAX];
    snprintf(plugin, sizeof plugin, "%s/Library/Application Support/FMStarship/Plugin/libStarshipPlugin.dylib", home ? home : "");
    const char *existing = getenv("DYLD_INSERT_LIBRARIES");
    char *libraries = NULL;
    if (!home || !*home)
        say("Starting FM without FM Starship, because HOME isn't set, so the plugin can't be found.");
    else if (access(plugin, R_OK) != 0)
        say("Starting FM without FM Starship, because %s can't be read (%s). Open the FM Starship app and choose "
            "FM Starship > Add FM Starship to FM, or clear FM's launch option in Steam.", plugin, strerror(errno));
    else if ((existing && *existing ? asprintf(&libraries, "%s:%s", plugin, existing) : asprintf(&libraries, "%s", plugin)) < 0)
        say("Starting FM without FM Starship, because there wasn't the memory to add it.");
    else {
        setenv("DYLD_INSERT_LIBRARIES", libraries, 1);
        free(libraries);
    }
    // Without these the Steam API restarts FM through Steam, which would lose the plugin.
    setenv("SteamAppId", "4530370", 0);
    setenv("SteamGameId", "4530370", 0);

    argv[1] = game;
    pid_t pid;
    int error = posix_spawn(&pid, game, NULL, NULL, argv + 1, environ);
    if (error != 0) {
        say("Couldn't start FM at %s (%s). Check FM's launch option in Steam ends with %%command%%.", game, strerror(error));
        return 1;
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
