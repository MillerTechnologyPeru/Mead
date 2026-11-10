#define _GNU_SOURCE
#include "mead_deps.h"
#include "mead_dl.h"
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
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// The loader's top level: map, lay out TLS, bind, make the images runnable,
// give the providers their startup, then run initializers dependency-first.

static bool providers_started;
static size_t bound_through;
static char *init_argv[2];

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

// The information each provider gets at startup; it stays valid for the
// life of the process, as providers keep the pointer.
static mead_startup_info startup_info;

static void start_provider(void *handle) {
    mead_provider_startup_fn startup =
        (mead_provider_startup_fn)dlsym(handle, MEAD_PROVIDER_STARTUP_SYMBOL);
    if (startup)
        startup(&startup_info);
}

static void providers_startup(const char *progname) {
    init_argv[0] = (char *)progname;
    startup_info = (mead_startup_info){
        .version = MEAD_STARTUP_INFO_VERSION,
        .argc = 1,
        .argv = init_argv,
        .envp = environ,
        .progname = progname,
        .data_dir = getenv("MEAD_DATA_DIR"),
        .lookup_symbol = startup_lookup_symbol,
        .load_library = startup_load_library,
        .lookup_symbol_after = mead_deps_lookup_after,
        .dl_open = mead_dlopen,
        .dl_sym = mead_dlsym,
        .dl_close = mead_dlclose,
        .dl_error = mead_dlerror,
        .dl_addr = mead_dladdr,
        .dl_iterate_phdr = mead_dl_iterate_phdr,
        .thread_setup = mead_tlv_thread_init,
        .thread_tls_bytes = mead_tlv_block_bytes(),
    };
    void **handles;
    const char **files;
    size_t count;
    mead_deps_providers(&handles, &files, &count);
    for (size_t index = 0; index < count; index++)
        start_provider(handles[index]);
    mead_deps_set_provider_opened(start_provider);
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

// An initializer, as bionic calls one. 0 and -1 are padding some linkers
// leave in the arrays.
static void call_initializer(uint64_t address) {
    if (address == 0 || address == UINT64_MAX)
        return;
    ((void (*)(int, char **, char **))(uintptr_t)address)(1, init_argv, environ);
}

static void run_initializers(mead_image *image) {
    const Elf64_Dyn *init = mead_image_dynamic(image, DT_INIT);
    if (init) {
        mead_trace("init", "running %s's DT_INIT", image->path);
        call_initializer((uint64_t)(uintptr_t)mead_image_address(image, (uint64_t)init->d_un.d_ptr));
    }
    const Elf64_Dyn *array = mead_image_dynamic(image, DT_INIT_ARRAY);
    const Elf64_Dyn *size = mead_image_dynamic(image, DT_INIT_ARRAYSZ);
    if (array && size) {
        uint64_t *addresses = mead_image_address(image, (uint64_t)array->d_un.d_ptr);
        size_t count = (size_t)size->d_un.d_val / sizeof(*addresses);
        for (size_t index = 0; index < count; index++) {
            mead_trace("init", "running %s's initializer %zu", image->path, index);
            call_initializer(addresses[index]);
        }
    }
}

// What an image needs, depth first, then the image. It is marked before any
// of that, so a dependency cycle ends and an initializer that dlopens its
// own library does not start again.
static void initialize(mead_image *image) {
    if (image->initialized)
        return;
    image->initialized = true;
    for (size_t index = 0; index < image->needed_count; index++)
        initialize(image->needed[index]);
    image_hooks(image);
    run_initializers(image);
}

// Overwrites instructions in a bound image.
static void write_code(uint32_t *code, const uint32_t *words, size_t count) {
    uint64_t page = (uint64_t)(uintptr_t)code & ~(uint64_t)4095;
    mprotect((void *)(uintptr_t)page, 8192, PROT_READ | PROT_WRITE | PROT_EXEC);
    memcpy(code, words, count * sizeof(uint32_t));
    __builtin___clear_cache((char *)code, (char *)(code + count));
    mprotect((void *)(uintptr_t)page, 8192, PROT_READ | PROT_EXEC);
}

// Functions that return at once, wherever an image defines them. Microsoft's
// telemetry is the one so far: it has no business reporting from a host
// that isn't what it thinks it is, and on the Minecraft versions protected by
// pairip, the SQLite it would open keeps its state in encrypted data.
static const char *const skipped_functions[] = {
    "_ZN9Microsoft12Applications6Events19TelemetrySystemBase5startEv",
};

static void skip_functions(mead_image *image) {
    static const uint32_t return_zero[] = { 0xd2800000, 0xd65f03c0 }; // mov x0, #0; ret
    for (size_t index = 0; index < sizeof(skipped_functions) / sizeof(skipped_functions[0]); index++) {
        const Elf64_Sym *symbol = mead_symbols_find(image, skipped_functions[index]);
        if (symbol && symbol->st_shndx != SHN_UNDEF && symbol->st_size >= sizeof(return_zero))
            write_code(mead_image_symbol_address(image, symbol), return_zero,
                       sizeof(return_zero) / sizeof(return_zero[0]));
    }
}

// MEAD_DEBUG_PATCH=library:offset:word,word — overwrites instructions in a
// bound image, for getting past one known fault to see what comes after it.
// A debugging aid only: nothing runs it unless the variable is set.
static void apply_one_debug_patch(mead_image *image, const char *patch);

// Several patches may be given, separated by ';'.
static void apply_debug_patch(mead_image *image, const char *patches) {
    if (!patches)
        return;
    for (const char *at = patches; at && *at; ) {
        const char *end = strchr(at, ';');
        size_t length = end ? (size_t)(end - at) : strlen(at);
        char one[512];
        if (length < sizeof(one)) {
            memcpy(one, at, length);
            one[length] = 0;
            apply_one_debug_patch(image, one);
        }
        at = end ? end + 1 : NULL;
    }
}

static void apply_one_debug_patch(mead_image *image, const char *patch) {
    const char *colon = strchr(patch, ':');
    if (!colon || !image->soname || strncmp(image->soname, patch, (size_t)(colon - patch)) != 0)
        return;
    char *rest = NULL;
    uint64_t offset = strtoull(colon + 1, &rest, 16);
    if (!rest || *rest != ':')
        return;
    uint32_t words[64];
    size_t count = 0;
    while ((*rest == ':' || *rest == ',') && count < sizeof(words) / sizeof(words[0]))
        words[count++] = (uint32_t)strtoul(rest + 1, &rest, 16);
    write_code(mead_image_address(image, offset), words, count);
    fprintf(stderr, "mead: patched %zu instructions in %s at 0x%lx\n", count, image->soname, (unsigned long)offset);
}

// MEAD_DEBUG_PATCH_LATE, the same thing, when `kill -USR2` asks: for catching
// a function on a call that comes long after the first.
void mead_apply_late_debug_patch(void) {
    size_t count = 0;
    mead_image *const *images = mead_deps_images(&count);
    for (size_t index = 0; index < count; index++)
        apply_debug_patch(images[index], getenv("MEAD_DEBUG_PATCH_LATE"));
}

void mead_bind_loaded(void) {
    mead_deps_lock();
    size_t count = 0;
    mead_image *const *images = mead_deps_images(&count);
    mead_tlv_layout();
    for (; bound_through < count; bound_through++) {
        mead_fixups_apply(images[bound_through]);
        mead_image_protect(images[bound_through]);
        skip_functions(images[bound_through]);
        apply_debug_patch(images[bound_through], getenv("MEAD_DEBUG_PATCH"));
    }
    mead_deps_unlock();
}

void mead_start_providers(const char *progname) {
    mead_deps_init();
    mead_deps_lock();
    if (!providers_started) {
        providers_started = true;
        providers_startup(progname);
    }
    mead_deps_unlock();
}

void *mead_load_library(const char *path, char **error) {
    // Held through the initializers, as the Android linker holds its own:
    // the lock is recursive, so one of them may dlopen.
    mead_deps_lock();
    mead_image *image = mead_deps_add(path, error);
    if (image) {
        // Every new image is bound and runnable before anything starts:
        // initializers see every library in place.
        mead_bind_loaded();
        if (!providers_started) {
            providers_started = true;
            providers_startup(path);
        }
        initialize(image);
    }
    mead_deps_unlock();
    return image;
}

void *mead_find_symbol(void *handle, const char *name) {
    if (!handle)
        return mead_deps_lookup(name);
    // As dlsym on a library handle is: the library, then what it needs.
    const mead_image *owner = NULL;
    const Elf64_Sym *symbol = mead_deps_find_in_tree(handle, name, &owner);
    if (symbol)
        return mead_image_symbol_address(owner, symbol);
    return mead_deps_provider_symbol(name);
}
