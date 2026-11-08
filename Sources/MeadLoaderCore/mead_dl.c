#define _GNU_SOURCE
#include "mead_dl.h"
#include "mead_deps.h"
#include "mead_image.h"
#include "mead_loader.h"
#include "mead_symbols.h"
#include "mead_tlv.h"

#include <dlfcn.h>
#include <link.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(sizeof(mead_dl_phdr_info) == sizeof(struct dl_phdr_info),
               "mead_dl_phdr_info must match the host's dl_phdr_info");
_Static_assert(offsetof(mead_dl_phdr_info, dlpi_tls_data) == offsetof(struct dl_phdr_info, dlpi_tls_data),
               "mead_dl_phdr_info must match the host's dl_phdr_info");

static __thread char error_text[512];
static __thread bool error_pending;

static void set_error(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(error_text, sizeof(error_text), format, arguments);
    va_end(arguments);
    error_pending = true;
}

const char *mead_dlerror(void) {
    if (!error_pending)
        return NULL;
    error_pending = false;
    return error_text;
}

// What dlopen(NULL) hands back, an address nothing else can be.
static char process_handle;

static void *open_library(const char *path) {
    char *error = NULL;
    void *image = mead_load_library(path, &error);
    if (!image)
        set_error("%s: %s", path, error ? error : "out of memory");
    free(error);
    return image;
}

void *mead_dlopen(const char *name, int flags) {
    (void)flags; // everything binds now, and is visible to everything
    if (!name)
        return &process_handle;
    if (strchr(name, '/'))
        return open_library(name);
    char path[4096];
    if (mead_deps_locate(name, path, sizeof(path)))
        return open_library(path);
    void *provider = mead_deps_provider_handle(name);
    if (!provider)
        set_error("library \"%s\" not found", name);
    return provider;
}

// Whether a handle is an Android image, rather than a provider's dlopen.
static bool is_image(const void *handle) {
    mead_deps_lock();
    size_t count = 0;
    mead_image *const *images = mead_deps_images(&count);
    bool found = false;
    for (size_t index = 0; index < count && !found; index++)
        found = images[index] == handle;
    mead_deps_unlock();
    return found;
}

void *mead_dlsym(void *handle, const char *name, const void *caller) {
    void *address;
    if (handle == RTLD_DEFAULT || handle == &process_handle)
        address = mead_deps_lookup(name);
    else if (handle == RTLD_NEXT)
        address = mead_deps_lookup_after(caller, name);
    else if (is_image(handle))
        address = mead_find_symbol(handle, name);
    else
        address = mead_deps_provider_symbol(name);
    if (!address)
        set_error("undefined symbol: %s", name);
    return address;
}

int mead_dlclose(void *handle) {
    (void)handle;
    return 0;
}

int mead_dladdr(const void *address, mead_dl_info *info) {
    mead_deps_lock();
    const mead_image *image = mead_deps_image_for(address);
    if (!image) {
        mead_deps_unlock();
        Dl_info host;
        if (!dladdr(address, &host))
            return 0;
        info->dli_fname = host.dli_fname;
        info->dli_fbase = host.dli_fbase;
        info->dli_sname = host.dli_sname;
        info->dli_saddr = host.dli_saddr;
        return 1;
    }

    info->dli_fname = image->path;
    info->dli_fbase = (void *)(uintptr_t)image->load_bias;
    info->dli_sname = NULL;
    info->dli_saddr = NULL;
    size_t count = 0;
    const Elf64_Sym *symbols = mead_symbols_table(image, &count);
    uint64_t offset = (uint64_t)(uintptr_t)address - image->load_bias;
    for (size_t index = 1; index < count; index++) {
        const Elf64_Sym *symbol = &symbols[index];
        if (symbol->st_shndx == SHN_UNDEF || ELF64_ST_TYPE(symbol->st_info) == STT_TLS)
            continue;
        if (offset >= symbol->st_value && offset < symbol->st_value + symbol->st_size) {
            info->dli_sname = image->strings + symbol->st_name;
            info->dli_saddr = mead_image_address(image, symbol->st_value);
            break;
        }
    }
    mead_deps_unlock();
    return 1;
}

int mead_dl_iterate_phdr(int (*callback)(mead_dl_phdr_info *, size_t, void *), void *data) {
    // Held through the callback, as bionic and glibc hold theirs: the list
    // must not move under an unwinder.
    mead_deps_lock();
    size_t count = 0;
    mead_image *const *images = mead_deps_images(&count);
    int result = 0;
    for (size_t index = 0; index < count && result == 0; index++) {
        const mead_image *image = images[index];
        mead_dl_phdr_info info = {
            .dlpi_addr = image->load_bias,
            .dlpi_name = image->path,
            .dlpi_phdr = image->phdr,
            .dlpi_phnum = image->phnum,
            .dlpi_adds = count,
            .dlpi_subs = 0,
            .dlpi_tls_modid = image->tls_module,
            .dlpi_tls_data = mead_tlv_block(image),
        };
        result = callback(&info, sizeof(info), data);
    }
    mead_deps_unlock();
    if (result)
        return result;
    return dl_iterate_phdr((int (*)(struct dl_phdr_info *, size_t, void *))callback, data);
}
