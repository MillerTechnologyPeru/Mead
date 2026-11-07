#ifndef MEAD_LOADER_H
#define MEAD_LOADER_H

// MeadLoaderCore's API: mapping an Android arm64 ELF library into this
// process, binding its imports to the providers and running its
// initializers.

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Maps `path` and the Android libraries it needs, binds them and runs their
// initializers, dependency first. Returns the library's handle, or NULL with
// `*error` (a static or malloc'd message; free it) saying why. A library
// already loaded is returned again.
void *mead_load_library(const char *path, char **error);

// Looks a symbol up in the library `handle` names, and everything loaded
// after it, as dlsym does. NULL if missing.
void *mead_find_symbol(void *handle, const char *name);

// Loads and binds without running initializers, then prints the library's
// imports grouped by soname, its relocation kinds, the JNI class names in
// its strings and any imports no provider answers — `mead --report`.
// Returns 0, or 1 when something could not be resolved.
int mead_report(const char *path);

#ifdef __cplusplus
}
#endif

#endif
