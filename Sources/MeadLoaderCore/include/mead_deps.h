#ifndef MEAD_DEPS_H
#define MEAD_DEPS_H

// The registry of loaded Android images: how a library's DT_NEEDED is
// answered — by the game's own directory, which holds libc++_shared.so and
// the engine's libraries, by a provider standing in for a system soname,
// or by a stub — and the order symbols are searched in, as the Android
// linker's is: the library its load began with, then what that needs,
// breadth first — and then, more forgivingly than Android, everything else
// in load order, and the providers.

#include "mead_image.h"

#include <stdbool.h>
#include <stddef.h>

// Finds the providers (next to the mead executable) and notes the first
// game library's directory, where DT_NEEDED looks for real files. Safe to
// call again.
void mead_deps_init(void);

// The registry's lock, which is recursive, for code that walks the images
// or holds them still while an initializer runs.
void mead_deps_lock(void);
void mead_deps_unlock(void);

// Maps `path` and, recursively, what it needs; registers everything. A
// library already loaded — by path or by soname — is returned again.
// Returns NULL with *error (malloc'd, free it) saying why.
mead_image *mead_deps_add(const char *path, char **error);

// Every registered image, in load order.
mead_image *const *mead_deps_images(size_t *count);

// The symbol `name` names from `from`: searched in `from` itself, then what
// it needs, breadth first, then in every other image in load order. The
// symbol's defining image is left in *owner when not NULL.
const Elf64_Sym *mead_deps_find_symbol(const mead_image *from, const char *name,
                                       const mead_image **owner);

// The same search kept to `from` and what it needs, as dlsym on a handle is.
const Elf64_Sym *mead_deps_find_in_tree(const mead_image *from, const char *name,
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
// table order, asking each one's mead_provider_symbol hook if it has one.
// NULL if missing.
void *mead_deps_provider_symbol(const char *name);

// The dlopen handle of the provider standing in for `soname`, opening it if
// it must; NULL when none does or it cannot be opened.
void *mead_deps_provider_handle(const char *soname);

// The providers loaded so far, each once, with their files, for the loader
// to call their startup and image hooks (mead_interface.h).
void mead_deps_providers(void ***handles, const char ***files, size_t *count);

// Has `callback` told of each provider opened from now on, for the startup
// it missed by not having been needed until now.
void mead_deps_set_provider_opened(void (*callback)(void *handle));

// Writes where `name` would be beside the game's libraries into `path`, and
// says whether a readable file is there.
bool mead_deps_locate(const char *name, char *path, size_t size);

#endif
