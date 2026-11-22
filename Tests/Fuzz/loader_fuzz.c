// A libFuzzer harness for the loader's ELF parsing: what MeadLoaderCore does
// with a library before any of its code runs. Each input is a file's bytes,
// taken through the steps a load takes them through — mapping, the dynamic
// table, symbols and their hash tables, thread-local storage, every form of
// relocation, and protecting the segments — and released. Initializers never
// run: the input is not code to be trusted with the process.
//
// A malformed library is refused with an error, or with mead_fatal, which
// this file defines in mead_log.c's place to come back here instead of
// exiting. Anything else — a crash, a sanitizer report, a hang — is a bug in
// the loader.
//
// Built and run by Scripts/fuzz-loader.sh.

#define _GNU_SOURCE
#include "mead_deps.h"
#include "mead_fixups.h"
#include "mead_image.h"
#include "mead_log.h"
#include "mead_symbols.h"
#include "mead_tlv.h"

#include <setjmp.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static jmp_buf fatal_return;
static bool fatal_armed;

// mead_log.c's functions, for the harness: tracing is off, and a fatal error
// ends the input, not the process.
bool mead_trace_wants(const char *category) {
    (void)category;
    return false;
}

void mead_trace(const char *category, const char *format, ...) {
    (void)category;
    (void)format;
}

void mead_fatal(const char *format, ...) {
    if (!fatal_armed) {
        va_list arguments;
        va_start(arguments, format);
        vfprintf(stderr, format, arguments);
        va_end(arguments);
        abort();
    }
    longjmp(fatal_return, 1);
}

// Reads what a load reads of an image's symbols: every name, and a lookup
// that hits and one that misses.
static void read_symbols(const mead_image *image) {
    size_t count = 0;
    const Elf64_Sym *symbols = mead_symbols_table(image, &count);
    size_t total = 0;
    for (size_t index = 1; index < count; index++) {
        const char *name = mead_image_string(image, symbols[index].st_name);
        if (name)
            total += strlen(name);
    }
    if (count > 1) {
        const char *first = mead_image_string(image, symbols[1].st_name);
        if (first)
            (void)mead_symbols_find(image, first);
    }
    (void)mead_symbols_find(image, "JNI_OnLoad");
    (void)mead_symbols_find(image, "");
    (void)total;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    static int fd = -1;
    static char path[64];
    if (fd < 0) {
        fd = memfd_create("mead-fuzz", 0);
        if (fd < 0)
            abort();
        snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    }
    if (ftruncate(fd, 0) != 0 || pwrite(fd, data, size, 0) != (ssize_t)size)
        abort();

    // volatile: read after longjmp.
    mead_image *volatile image = NULL;
    char *volatile error = NULL;
    fatal_armed = true;
    if (setjmp(fatal_return) == 0) {
        char *why = NULL;
        image = mead_image_open(path, &why);
        error = why;
        if (image && mead_symbols_setup(image, &why)) {
            error = why;
            mead_tlv_add(image);
            read_symbols(image);
            // As mead_deps_add leaves an image with no dependencies.
            const Elf64_Dyn *soname = mead_image_dynamic(image, DT_SONAME);
            if (soname)
                (void)mead_image_string(image, soname->d_un.d_val);
            image->root = image;
            mead_fixups_apply(image);
            mead_image_protect(image);
        } else {
            error = why;
        }
    }
    fatal_armed = false;
    free(error);
    mead_image_destroy(image);
    return 0;
}
