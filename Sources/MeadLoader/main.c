// mead: runs arm64 Android ELF libraries — Android games' own .so files and
// the NDK libraries they need — on arm64 Linux, binding their imports to
// Linux providers that stand in for bionic, the NDK and the JVM.

#define _GNU_SOURCE
#include "mead_loader.h"
#include "mead_log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void usage(FILE *out) {
    fputs("usage: mead [options] <library.so | game directory> [arguments...]\n"
          "\n"
          "options:\n"
          "  --report    load and bind without running; print imports, missing\n"
          "              symbols and JNI class names\n"
          "  --strict    fail when a non-weak import cannot be resolved\n"
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
          "and assets/, as mcpelauncher keeps them.\n",
          out);
}

int main(int argc, char **argv) {
    bool report = false;
    int first = 1;
    for (; first < argc; first++) {
        if (strcmp(argv[first], "--report") == 0)
            report = true;
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
    mead_fatal("loading comes with the loader; only usage is here so far%s", report ? " (report too)" : "");
}
