#include "bionic_internal.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// Everything Android code may import from libc.so, libm.so, libdl.so,
// liblog.so and libz.so: this table, and nothing else. A name here either
// goes to a shim, or is one whose ABI Scripts/compare-bionic-abi.sh shows to
// be the same in glibc. A name not here stays unresolved and says so, rather
// than reaching a glibc function with a different layout.

const mead_startup_info *bionic_loader;

void mead_bionic_startup(const mead_startup_info *info) {
    bionic_loader = info;
}

#define SHIM(name) extern void bionic_##name(void);
#define PASS(name)
#define ALIAS(name, host)
#define ZLIB(name)
#include "bionic_symbols.inc"
#undef SHIM
#undef PASS
#undef ALIAS
#undef ZLIB

typedef enum { FROM_SHIM, FROM_HOST, FROM_ZLIB } origin;

typedef struct entry {
    const char *name;
    void *shim;           // FROM_SHIM
    const char *host;     // otherwise, the name to ask for
    origin origin;
} entry;

static entry table[] = {
#define SHIM(name) { #name, (void *)bionic_##name, NULL, FROM_SHIM },
#define PASS(name) { #name, NULL, #name, FROM_HOST },
#define ALIAS(name, target) { #name, NULL, #target, FROM_HOST },
#define ZLIB(name) { #name, NULL, #name, FROM_ZLIB },
#include "bionic_symbols.inc"
};
enum { TABLE_COUNT = sizeof(table) / sizeof(table[0]) };

static int compare_entries(const void *left, const void *right) {
    return strcmp(((const entry *)left)->name, ((const entry *)right)->name);
}

static void sort_table(void) {
    qsort(table, TABLE_COUNT, sizeof(table[0]), compare_entries);
    for (size_t index = 1; index < TABLE_COUNT; index++)
        if (strcmp(table[index - 1].name, table[index].name) == 0) {
            fprintf(stderr, "mead: %s is in the bionic table twice\n", table[index].name);
            abort();
        }
}

// zlib is an ordinary library the host may or may not have: opened when
// something first needs it.
static void *zlib;

static void open_zlib(void) {
    zlib = dlopen("libz.so.1", RTLD_NOW | RTLD_LOCAL);
}

void *mead_bionic_lookup(const char *name) {
    static pthread_once_t sorted = PTHREAD_ONCE_INIT;
    pthread_once(&sorted, sort_table);
    entry key = { .name = name };
    const entry *found = bsearch(&key, table, TABLE_COUNT, sizeof(table[0]), compare_entries);
    if (!found)
        return NULL;
    switch (found->origin) {
    case FROM_SHIM:
        return found->shim;
    case FROM_HOST:
        return dlsym(RTLD_DEFAULT, found->host);
    case FROM_ZLIB: {
        static pthread_once_t opened = PTHREAD_ONCE_INIT;
        pthread_once(&opened, open_zlib);
        return zlib ? dlsym(zlib, found->host) : NULL;
    }
    }
    return NULL;
}
