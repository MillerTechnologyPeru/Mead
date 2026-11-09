// mead: runs arm64 Android ELF libraries — Android games' own .so files and
// the NDK libraries they need — on arm64 Linux, binding their imports to
// Linux providers that stand in for bionic, the NDK and the JVM.

#define _GNU_SOURCE
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
          "  -h, --help  show this help\n"
          "\n"
          "environment:\n"
          "  MEAD_TRACE          comma-separated: load, bind, init, jni, all\n"
          "  MEAD_STRICT         1: abort on an unresolved import when called\n"
          "  MEAD_UNIMPLEMENTED  continue: an unresolved function reports itself\n"
          "                      once and returns 0 instead of aborting\n"
          "  MEAD_DATA_DIR       where the game's files are, when the argument\n"
          "                      is a library rather than a directory\n"
          "\n"
          "A game directory is one extracted from its APK: lib/arm64-v8a/*.so\n"
          "and assets/, as mcpelauncher keeps them; the largest library there\n"
          "is the game's.\n",
          out);
}

// The game's library in a directory extracted from an APK: the largest .so
// in lib/arm64-v8a, which for every game checked so far is the game's own.
static char *library_in(const char *directory) {
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
        else if (strcmp(argv[first], "--strict") == 0)
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

    char *target = argv[first];
    struct stat status;
    if (stat(target, &status) == 0 && S_ISDIR(status.st_mode)) {
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
    return 0;
}
