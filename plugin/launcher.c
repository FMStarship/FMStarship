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
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

// A start with the plugin counts against it when FM closes on a signal or with an error within this many seconds. FM
// loads the plugin at once, and adds its tab 30 to 70 seconds later on an M-series Mac; a slower Mac or the first start
// after an FM update takes longer, so three minutes. A crash later than that is past the plugin's start.
#ifndef CRASH_WINDOW_SECONDS
#define CRASH_WINDOW_SECONDS 180
#endif
// After this many such starts in a row with the same plugin, FM starts without it until the plugin is replaced.
#define CRASHES_TO_STOP 2

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
// FM's version too, for the status file, or empty.
static void executable(const char *bundle, char *name, size_t size, char *version, size_t versionSize) {
    const char *fallback = "Football Manager 27";
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)bundle, (CFIndex)strlen(bundle), true);
    CFBundleRef app = url ? CFBundleCreate(NULL, url) : NULL;
    CFTypeRef value = app ? CFBundleGetValueForInfoDictionaryKey(app, kCFBundleExecutableKey) : NULL;
    if (!value || CFGetTypeID(value) != CFStringGetTypeID() || !CFStringGetFileSystemRepresentation(value, name, (CFIndex)size)
        || !*name) {
        say("No CFBundleExecutable in %s/Contents/Info.plist, so trying \"%s\"", bundle, fallback);
        snprintf(name, size, "%s", fallback);
    }
    CFTypeRef shown = app ? CFBundleGetValueForInfoDictionaryKey(app, CFSTR("CFBundleShortVersionString")) : NULL;
    if (!shown || CFGetTypeID(shown) != CFStringGetTypeID()
        || !CFStringGetCString(shown, version, (CFIndex)versionSize, kCFStringEncodingUTF8))
        *version = '\0';
    if (app) CFRelease(app);
    if (url) CFRelease(url);
}

// The crash-loop breaker keeps its count in the plugin's folder. Whatever goes wrong with that, FM starts as it would
// without the breaker, with the plugin.

// Writes text to folder/name through a new file put in its place, so a reader never sees half of it.
static int write_atomically(const char *folder, const char *name, const char *text) {
    char temporary[PATH_MAX], path[PATH_MAX];
    if (snprintf(temporary, sizeof temporary, "%s/.%s.XXXXXX", folder, name) >= (int)sizeof temporary
        || snprintf(path, sizeof path, "%s/%s", folder, name) >= (int)sizeof path) {
        errno = ENAMETOOLONG;
        return -1;
    }
    int file = mkstemp(temporary);
    if (file < 0) return -1;
    size_t length = strlen(text), done = 0;
    while (done < length) {
        ssize_t wrote = write(file, text + done, length - done);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) break;
        done += (size_t)wrote;
    }
    int failed = done < length || fchmod(file, 0644) != 0;
    int saved = errno;
    if (close(file) != 0 && !failed) { failed = 1; saved = errno; }
    if (!failed && rename(temporary, path) == 0) return 0;
    if (!failed) saved = errno;
    unlink(temporary);
    errno = saved;
    return -1;
}

// Text in double quotes for JSON.
static void quoted(char *out, size_t size, const char *text) {
    size_t used = 0;
    if (size < 3) { if (size) *out = '\0'; return; }
    out[used++] = '"';
    for (const unsigned char *c = (const unsigned char *)text; *c && used + 8 < size; c++) {
        if (*c == '"' || *c == '\\') { out[used++] = '\\'; out[used++] = (char)*c; }
        else if (*c < 0x20) used += (size_t)snprintf(out + used, size - used, "\\u%04x", *c);
        else out[used++] = (char)*c;
    }
    out[used++] = '"';
    out[used] = '\0';
}

// status.json tells the app the plugin was kept out of FM, and why, for the player.
static void write_status(const char *folder, const char *detail, const char *version) {
    char stamp[32], when[48], why[1024], fm[256], text[2048];
    time_t now = time(NULL);
    struct tm utc;
    strftime(stamp, sizeof stamp, "%Y-%m-%dT%H:%M:%SZ", gmtime_r(&now, &utc));
    quoted(when, sizeof when, stamp);
    quoted(why, sizeof why, detail);
    quoted(fm, sizeof fm, version);
    snprintf(text, sizeof text, "{\"plugin\": \"off\", \"reason\": \"crash-loop\", \"detail\": %s, \"at\": %s, \"fm\": %s}\n",
             why, when, fm);
    if (write_atomically(folder, "status.json", text) != 0)
        say("Couldn't write %s/status.json, so the app can't say why (%s).", folder, strerror(errno));
}

// Takes away the status file the breaker wrote, once the plugin goes back in. One for another reason stays.
static void clear_status(const char *folder) {
    char path[PATH_MAX], text[4096];
    if (snprintf(path, sizeof path, "%s/status.json", folder) >= (int)sizeof path) return;
    int file = open(path, O_RDONLY | O_NONBLOCK);
    if (file < 0) return;
    ssize_t length = read(file, text, sizeof text - 1);
    close(file);
    if (length <= 0) return;
    text[length] = '\0';
    if (strstr(text, "\"crash-loop\"")) unlink(path);
}

// Which plugin build is there. A new copy, from the app's update, a new add or Scripts/install-plugin.sh, is a new file.
static bool plugin_build(const char *plugin, char *build, size_t size) {
    struct stat info;
    if (stat(plugin, &info) != 0) return false;
    return snprintf(build, size, "%llu:%llu:%lld:%ld.%09ld", (unsigned long long)info.st_dev,
                    (unsigned long long)info.st_ino, (long long)info.st_size, (long)info.st_mtimespec.tv_sec,
                    (long)info.st_mtimespec.tv_nsec) < (int)size;
}

// The breaker's count: the plugin build and how many starts with it in a row ended soon after starting. A count that's
// missing or can't be read is no count. Its files are opened so that one that isn't a plain file can't hold FM's start up.
static int read_count(const char *folder, const char *build) {
    char path[PATH_MAX], text[256], seen[128];
    int crashes = 0;
    if (snprintf(path, sizeof path, "%s/launcher-starts", folder) >= (int)sizeof path) return 0;
    int file = open(path, O_RDONLY | O_NONBLOCK);
    if (file < 0) return 0;
    ssize_t length = read(file, text, sizeof text - 1);
    close(file);
    if (length <= 0) return 0;
    text[length] = '\0';
    if (sscanf(text, "%127s %9d", seen, &crashes) != 2 || crashes < 0 || strcmp(seen, build) != 0) return 0;
    return crashes;
}

static void write_count(const char *folder, const char *build, int crashes) {
    char text[256];
    snprintf(text, sizeof text, "%s %d\n", build, crashes);
    if (write_atomically(folder, "launcher-starts", text) != 0)
        say("Couldn't note how FM's start went in %s/launcher-starts (%s).", folder, strerror(errno));
}

int main(int argc, char **argv) {
    if (argc < 2) {
        say("Steam gave no game to start. FM's launch option needs %%command%% after the launcher.");
        return 1;
    }

    // %command% is the path to fm.app, perhaps with a slash on the end.
    char bundle[PATH_MAX], game[PATH_MAX], version[128] = "";
    snprintf(bundle, sizeof bundle, "%s", argv[1]);
    size_t length = strlen(bundle);
    while (length > 1 && bundle[length - 1] == '/') bundle[--length] = '\0';
    if (length > 4 && strcmp(bundle + length - 4, ".app") == 0) {
        char name[NAME_MAX + 1];
        executable(bundle, name, sizeof name, version, sizeof version);
        snprintf(game, sizeof game, "%s/Contents/MacOS/%s", bundle, name);
    } else
        snprintf(game, sizeof game, "%s", argv[1]);

    // dyld ends a process whose inserted library can't be loaded, so the plugin only goes in if it's there.
    // Steam's overlay may already be in the list, so the plugin goes in front of it.
    const char *home = getenv("HOME");
    char folder[PATH_MAX], plugin[PATH_MAX], build[128];
    snprintf(folder, sizeof folder, "%s/Library/Application Support/FMStarship/Plugin", home ? home : "");
    snprintf(plugin, sizeof plugin, "%s/libStarshipPlugin.dylib", folder);
    const char *existing = getenv("DYLD_INSERT_LIBRARIES");
    char *libraries = NULL;
    // Whether this start is one the breaker counts, and the count before it.
    bool counted = false, inserted = false;
    int crashes = 0;
    if (!home || !*home)
        say("Starting FM without FM Starship, because HOME isn't set, so the plugin can't be found.");
    else if (access(plugin, R_OK) != 0)
        say("Starting FM without FM Starship, because %s can't be read (%s). Open the FM Starship app and choose "
            "FM Starship > Add FM Starship to FM, or clear FM's launch option in Steam.", plugin, strerror(errno));
    else if ((counted = plugin_build(plugin, build, sizeof build))
             && (crashes = read_count(folder, build)) >= CRASHES_TO_STOP) {
        counted = false;
        say("Starting FM without FM Starship, because FM closed within %d minutes of starting with this build of it %d "
            "times in a row. It goes back in when FM Starship updates, or when you choose FM Starship > Add FM Starship "
            "to FM in the app.", CRASH_WINDOW_SECONDS / 60, crashes);
        write_status(folder, "FM closed soon after starting with FM Starship twice in a row, so FM now starts without it "
                     "until FM Starship updates or you choose Add FM Starship to FM again.", version);
    } else if ((existing && *existing ? asprintf(&libraries, "%s:%s", plugin, existing) : asprintf(&libraries, "%s", plugin)) < 0)
        say("Starting FM without FM Starship, because there wasn't the memory to add it.");
    else {
        setenv("DYLD_INSERT_LIBRARIES", libraries, 1);
        free(libraries);
        inserted = true;
        clear_status(folder);
    }
    counted = counted && inserted;
    // Without these the Steam API restarts FM through Steam, which would lose the plugin.
    setenv("SteamAppId", "4530370", 0);
    setenv("SteamGameId", "4530370", 0);

    argv[1] = game;
    pid_t pid;
    struct timespec started, ended;
    clock_gettime(CLOCK_MONOTONIC, &started);
    int error = posix_spawn(&pid, game, NULL, NULL, argv + 1, environ);
    if (error != 0) {
        say("Couldn't start FM at %s (%s). Check FM's launch option in Steam ends with %%command%%.", game, strerror(error));
        return 1;
    }
    int status = 0;
    pid_t waited;
    while ((waited = waitpid(pid, &status, 0)) < 0 && errno == EINTR) {}
    clock_gettime(CLOCK_MONOTONIC, &ended);

    // How the start with the plugin ended. A quick quit of the player's own changes nothing.
    if (counted && waited == pid) {
        long seconds = (long)(ended.tv_sec - started.tv_sec);
        bool failed = WIFSIGNALED(status) || (WIFEXITED(status) && WEXITSTATUS(status) != 0);
        if (failed && seconds < CRASH_WINDOW_SECONDS) {
            crashes++;
            char how[128];
            if (WIFSIGNALED(status)) snprintf(how, sizeof how, "on signal %d (%s)", WTERMSIG(status), strsignal(WTERMSIG(status)));
            else snprintf(how, sizeof how, "with status %d", WEXITSTATUS(status));
            say("FM closed %s %ld seconds after it started with FM Starship, %d of %d such starts in a row before FM "
                "starts without it.", how, seconds, crashes, CRASHES_TO_STOP);
            write_count(folder, build, crashes);
        } else if (seconds >= CRASH_WINDOW_SECONDS && crashes > 0)
            write_count(folder, build, 0);
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
