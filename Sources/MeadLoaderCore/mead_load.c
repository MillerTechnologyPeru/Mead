#define _GNU_SOURCE
#include "mead_deps.h"
#include "mead_fixups.h"
#include "mead_image.h"
#include "mead_interface.h"
#include "mead_loader.h"
#include "mead_log.h"
#include "mead_symbols.h"
#include "mead_tlv.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// The loader's top level: map, lay out TLS, bind, give the providers their
// startup, then run initializers in load order — which is dependency-first,
// the registry appending what an image needs before the image itself.

static bool providers_started;
static size_t bound_through, initialized_through;

// The startup information the providers get, once: the game library the
// loader was pointed at, and the lookups mead_interface.h describes.
static void *startup_lookup_symbol(const char *soname, const char *name) {
    if (soname) {
        size_t count = 0;
        mead_image *const *images = mead_deps_images(&count);
        for (size_t index = 0; index < count; index++)
            if (images[index]->soname && strcmp(images[index]->soname, soname) == 0) {
                const Elf64_Sym *symbol = mead_symbols_find(images[index], name);
                if (symbol && symbol->st_shndx != SHN_UNDEF)
                    return mead_image_symbol_address(images[index], symbol);
            }
    }
    return mead_deps_lookup(name);
}

static bool startup_load_library(const char *path) {
    char *error = NULL;
    void *loaded = mead_load_library(path, &error);
    free(error);
    return loaded != NULL;
}

static void providers_startup(const char *progname) {
    static char *argv_storage[2];
    argv_storage[0] = (char *)progname;
    argv_storage[1] = NULL;
    mead_startup_info info = {
        .version = MEAD_STARTUP_INFO_VERSION,
        .argc = 1,
        .argv = argv_storage,
        .envp = environ,
        .progname = progname,
        .data_dir = getenv("MEAD_DATA_DIR"),
        .lookup_symbol = startup_lookup_symbol,
        .load_library = startup_load_library,
        .lookup_symbol_after = mead_deps_lookup_after,
    };
    void **handles;
    const char **files;
    size_t count;
    mead_deps_providers(&handles, &files, &count);
    for (size_t index = 0; index < count; index++) {
        if (!handles[index])
            continue;
        mead_provider_startup_fn startup =
            (mead_provider_startup_fn)dlsym(handles[index], MEAD_PROVIDER_STARTUP_SYMBOL);
        if (startup)
            startup(&info);
    }
}

// The image hooks the providers may export (mead_interface.h), called just
// before an image's initializers: where the FakeJNI runtime takes stock of
// an image's registered natives.
static void image_hooks(mead_image *image) {
    mead_image_info info = {
        .path = image->path,
        .base = (const void *)(uintptr_t)image->load_bias,
        .phdr = image->phdr,
        .phnum = image->phnum,
        .phentsize = image->phentsize,
    };
    void **handles;
    const char **files;
    size_t count;
    mead_deps_providers(&handles, &files, &count);
    for (size_t index = 0; index < count; index++) {
        if (!handles[index])
            continue;
        mead_provider_image_fn hook =
            (mead_provider_image_fn)dlsym(handles[index], MEAD_PROVIDER_IMAGE_INIT_SYMBOL);
        if (hook)
            hook(&info);
    }
}

static void run_initializers(mead_image *image) {
    const Elf64_Dyn *init = mead_image_dynamic(image, DT_INIT);
    if (init) {
        void (*function)(void) = mead_image_address(image, (uint64_t)init->d_un.d_ptr);
        mead_trace("init", "running %s's DT_INIT", image->path);
        function();
    }
    const Elf64_Dyn *array = mead_image_dynamic(image, DT_INIT_ARRAY);
    const Elf64_Dyn *size = mead_image_dynamic(image, DT_INIT_ARRAYSZ);
    if (array && size) {
        uint64_t *addresses = mead_image_address(image, (uint64_t)array->d_un.d_ptr);
        size_t count = (size_t)size->d_un.d_val / sizeof(*addresses);
        for (size_t index = 0; index < count; index++) {
            mead_trace("init", "running %s's initializer %zu", image->path, index);
            ((void (*)(void))(uintptr_t)addresses[index])();
        }
    }
}

void *mead_load_library(const char *path, char **error) {
    mead_image *image = mead_deps_add(path, error);
    if (!image)
        return NULL;

    // Lay out what the new images want in TLS, bind them, and only then
    // start anything: initializers see every library in place.
    size_t count = 0;
    mead_image *const *images = mead_deps_images(&count);
    mead_tlv_layout();
    for (; bound_through < count; bound_through++)
        mead_fixups_apply(images[bound_through]);

    for (; initialized_through < count; initialized_through++) {
        mead_image *at = images[initialized_through];
        if (!providers_started) {
            providers_startup(path);
            providers_started = true;
        }
        image_hooks(at);
        run_initializers(at);
        mead_image_protect(at);
    }
    return image;
}

void *mead_find_symbol(void *handle, const char *name) {
    if (!handle)
        return mead_deps_lookup(name);
    // As dlsym on a library handle is: the library, then what it needs.
    const mead_image *owner = NULL;
    const Elf64_Sym *symbol = mead_deps_find_symbol(handle, name, &owner);
    if (symbol)
        return mead_image_symbol_address(owner, symbol);
    return mead_deps_lookup(name);
}
