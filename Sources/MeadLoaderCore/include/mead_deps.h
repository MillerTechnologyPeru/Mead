#ifndef MEAD_DEPS_H
#define MEAD_DEPS_H

// The registry of loaded Android images: how a library's DT_NEEDED is
// answered — by the game's own directory, which holds libc++_shared.so and
// the engine's libraries, by a provider standing in for a system soname,
// or by a stub — and the order symbols are searched in, as the Android
// linker's is: what the image needs, breadth first, then everything in
// load order, then the providers.

#include "mead_image.h"

#include <stdbool.h>
#include <stddef.h>

// Finds the providers (next to the mead executable) and notes the first
// game library's directory, where DT_NEEDED looks for real files. Safe to
// call again.
void mead_deps_init(void);

// Maps `path` and, recursively, what it needs; registers everything. A
// library already loaded — by path or by soname — is returned again.
// Returns NULL with *error (malloc'd, free it) saying why.
mead_image *mead_deps_add(const char *path, char **error);

// Every registered image, in load order.
mead_image *const *mead_deps_images(size_t *count);

// The symbol `name` names for an import in `from`: searched in what `from`
// needs, breadth first, then in every image in load order, then in every
// provider. The symbol's defining image is left in *owner when not NULL.
const Elf64_Sym *mead_deps_find_symbol(const mead_image *from, const char *name,
                                       const mead_image **owner);

// The address a name names, searched everywhere as dlsym(RTLD_DEFAULT)
// is: the images in load order, then the providers. NULL if missing.
void *mead_deps_lookup(const char *name);

// The address a name names as dlsym(RTLD_NEXT) is for code at `caller`:
// the images loaded after the one `caller` is in, then the providers.
// NULL if missing.
void *mead_deps_lookup_after(const void *caller, const char *name);

// The image `address` is in, or NULL. dlsym and dladdr's first step.
mead_image *mead_deps_image_for(const void *address);

// Whether a provider stands in for a soname, and which file it is; NULL
// when no provider does.
const char *mead_deps_provider_for(const char *soname);

// A provider's symbol, as the providers' own dlsym: every provider, in
// table order. NULL if missing.
void *mead_deps_provider_symbol(const char *name);

// The providers loaded so far, with their files, for the loader to call
// their startup and image hooks (mead_interface.h).
void mead_deps_providers(void ***handles, const char ***files, size_t *count);

#endif
