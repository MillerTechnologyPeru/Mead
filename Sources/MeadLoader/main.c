// mead: runs arm64 Android ELF libraries — Android games' own .so files and
// the NDK libraries they need — on arm64 Linux, binding their imports to
// Linux providers that stand in for bionic, the NDK and the JVM.

#define _GNU_SOURCE
#include "mead_interface.h"
#include "mead_loader.h"
#include "mead_log.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static void usage(FILE *out) {
    fputs("usage: mead [options] <library.so | game directory> [arguments...]\n"
          "\n"
          "options:\n"
          "  --report    load and bind without running; print imports, missing\n"
          "              symbols and JNI class names\n"
          "  --strict    fail when a non-weak import cannot be resolved\n"
          "  --selftest  load the library, run its mead_selftest and exit\n"
          "              with what it returns\n"
          "  --graphics-api auto|gles|vulkan\n"
          "              the graphics API the app gets; the same as\n"
          "              MEAD_GRAPHICS_API\n"
          "  -h, --help  show this help\n"
          "\n"
          "environment:\n"
          "  MEAD_TRACE          comma-separated: load, bind, init, jni, all\n"
          "  MEAD_STRICT         1: abort on an unresolved import when called\n"
          "  MEAD_UNIMPLEMENTED  continue: an unresolved function reports itself\n"
          "                      once and returns 0 instead of aborting\n"
          "  MEAD_GRAPHICS_API   auto (the default) offers both; gles or vulkan\n"
          "                      hides the other from the game\n"
          "  MEAD_CRASH_REPORT   1: print registers and frames on a crash\n"
          "  MEAD_DATA_DIR       where the game's files are, when the argument\n"
          "                      is a library rather than a directory\n"
          "\n"
          "A game directory is one extracted from its APK: lib/arm64-v8a/*.so\n"
          "and assets/, as mcpelauncher keeps them; the largest library there\n"
          "is the game's.\n",
          out);
}

// A Unity game's libraries: libmain.so starts it, through Unity's Java, and
// loads libunity.so and the game's code after it. NULL for any other game.
static char *unity_library_directory(const char *directory) {
    char *libraries = NULL, *probe = NULL;
    if (asprintf(&libraries, "%s/lib/arm64-v8a", directory) < 0)
        return NULL;
    struct stat status;
    int found = asprintf(&probe, "%s/libunity.so", libraries) >= 0 && stat(probe, &status) == 0;
    free(probe);
    probe = NULL;
    found = found && asprintf(&probe, "%s/libmain.so", libraries) >= 0 && stat(probe, &status) == 0;
    free(probe);
    if (found)
        return libraries;
    free(libraries);
    return NULL;
}

// The game's library in a directory extracted from an APK: the largest .so
// in lib/arm64-v8a, which for every game checked so far is the game's own.
// Unity's games are the exception, and start from libmain.so.
static char *library_in(const char *directory) {
    char *unity = unity_library_directory(directory);
    if (unity) {
        char *main_library = NULL;
        int made = asprintf(&main_library, "%s/libmain.so", unity);
        free(unity);
        return made >= 0 ? main_library : NULL;
    }
    char libraries[4096];
    snprintf(libraries, sizeof(libraries), "%s/lib/arm64-v8a", directory);
    DIR *open = opendir(libraries);
    if (!open)
        return NULL;
    char *best = NULL;
    long best_size = 0;
    struct dirent *entry;
    while ((entry = readdir(open))) {
        size_t length = strlen(entry->d_name);
        if (length < 4 || strcmp(entry->d_name + length - 3, ".so") != 0)
            continue;
        char *path = NULL;
        if (asprintf(&path, "%s/%s", libraries, entry->d_name) < 0)
            continue;
        struct stat status;
        if (stat(path, &status) == 0 && status.st_size > best_size) {
            free(best);
            best = path;
            best_size = status.st_size;
        } else
            free(path);
    }
    closedir(open);
    return best;
}

int main(int argc, char **argv) {
    bool report = false, selftest = false;
    int first = 1;
    for (; first < argc; first++) {
        if (strcmp(argv[first], "--report") == 0)
            report = true;
        else if (strcmp(argv[first], "--selftest") == 0)
            selftest = true;
        else if (strcmp(argv[first], "--graphics-api") == 0) {
            if (first + 1 >= argc) {
                usage(stderr);
                return 1;
            }
            setenv("MEAD_GRAPHICS_API", argv[++first], 1);
        } else if (strcmp(argv[first], "--strict") == 0)
            setenv("MEAD_STRICT", "1", 0);
        else if (strcmp(argv[first], "-h") == 0 || strcmp(argv[first], "--help") == 0) {
            usage(stdout);
            return 0;
        } else
            break;
    }
    if (first >= argc) {
        usage(stderr);
        return 1;
    }
    if (mead_graphics_api() == MEAD_GRAPHICS_INVALID) {
        fprintf(stderr, "mead: MEAD_GRAPHICS_API is \"%s\"; it can be auto, gles or vulkan\n",
                getenv("MEAD_GRAPHICS_API"));
        return 1;
    }

    if (getenv("MEAD_CRASH_REPORT"))
        mead_install_crash_report();

    char *target = argv[first];
    char *unity = NULL;
    struct stat status;
    if (stat(target, &status) == 0 && S_ISDIR(status.st_mode)) {
        unity = unity_library_directory(target);
        char *inside = library_in(target);
        if (!inside) {
            fprintf(stderr, "mead: no lib/arm64-v8a/*.so in %s\n", target);
            return 1;
        }
        if (!getenv("MEAD_DATA_DIR"))
            setenv("MEAD_DATA_DIR", target, 0);
        target = inside;
        mead_trace("load", "the game's library in the directory is %s", target);
    }

    if (report)
        return mead_report(target);

    char *error = NULL;
    void *image = mead_load_library(target, &error);
    if (!image) {
        fprintf(stderr, "mead: %s\n", error ? error : "out of memory");
        free(error);
        return 1;
    }
    mead_trace("load", "loaded; the game's initializers have run");
    if (selftest) {
        int (*test)(void) = (int (*)(void))mead_find_symbol(image, "mead_selftest");
        if (!test) {
            fprintf(stderr, "mead: %s has no mead_selftest\n", target);
            return 1;
        }
        int result = test();
        printf("%s: %s (%d)\n", target, result == 0 ? "passed" : "FAILED", result);
        fflush(stdout);
        return result == 0 ? 0 : 1;
    }

    // A Unity game: its runner plays Unity's Java, which loads the rest.
    if (unity) {
        int (*run)(const char *) = (int (*)(const char *))mead_find_symbol(NULL, "mead_android_run_unity");
        if (!run) {
            fprintf(stderr, "mead: no provider can run a Unity game\n");
            return 1;
        }
        return run(unity);
    }

    // A NativeActivity's entry point: run it as Android would.
    void *on_create = mead_find_symbol(image, "ANativeActivity_onCreate");
    if (on_create) {
        int (*run)(void *, const char *) =
            (int (*)(void *, const char *))mead_find_symbol(NULL, "mead_android_run_activity");
        if (!run) {
            fprintf(stderr, "mead: no provider can run an activity\n");
            return 1;
        }
        return run(on_create, target);
    }

    // Or a GameActivity's, whose entry is the native half of its Java class.
    void *initialize = mead_find_symbol(image, "Java_com_google_androidgamesdk_GameActivity_initializeNativeCode");
    if (initialize) {
        int (*run)(void *, void *, const char *) =
            (int (*)(void *, void *, const char *))mead_find_symbol(NULL, "mead_android_run_game_activity");
        if (!run) {
            fprintf(stderr, "mead: no provider can run a GameActivity\n");
            return 1;
        }
        return run(initialize, mead_find_symbol(image, "GameActivity_register"), target);
    }
    return 0;
}
