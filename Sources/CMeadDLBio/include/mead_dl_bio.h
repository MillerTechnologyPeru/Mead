#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// libdl_bio for ART running in Mead's process.
//
// ART loads every native library through bionic_dlopen: its own (libjavacore,
// libopenjdk, built for glibc) and apps' NDK libraries (built for bionic).
// These functions send each library to the linker it was built for: glibc
// libraries to the system's, bionic ones to Mead's loader. Loaded with
// RTLD_GLOBAL before libart, they take the place of the libdl_bio libart
// was linked with.

// Mead's loader, as the provider interface hands it over. Until it is
// installed, bionic libraries fail to load.
typedef struct mead_dl_bio_loader {
    void *(*open)(const char *name, int flags);
    void *(*sym)(void *handle, const char *name, const void *caller);
    int (*close)(void *handle);
    const char *(*error)(void);
} mead_dl_bio_loader;

void mead_dl_bio_install(const mead_dl_bio_loader *loader);

// The same, as four functions, for callers that can't build the struct.
void mead_dl_bio_install_functions(void *(*open)(const char *name, int flags),
                                   void *(*sym)(void *handle, const char *name, const void *caller),
                                   int (*close)(void *handle), const char *(*error)(void));

// Adds a directory to look in for libraries asked for by name alone, before
// the system's search path: ART asks for its own (libjavacore.so) that way.
void mead_dl_bio_add_search_directory(const char *directory);

// Whether the ELF library at `path` was built for bionic: it needs libc.so,
// where everything built for glibc needs libc.so.6 or is glibc itself. False
// if it can't be read.
bool mead_dl_bio_is_bionic_library(const char *path);

// libdl_bio's interface, as ART calls it.
void dl_parse_library_path(const char *path, char *delim);
void *bionic_dlopen(const char *filename, int flag);
const char *bionic_dlerror(void);
void *bionic_dlsym(void *handle, const char *symbol);
int bionic_dlclose(void *handle);

#ifdef __cplusplus
}
#endif
