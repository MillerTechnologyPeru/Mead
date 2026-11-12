#define _GNU_SOURCE
#include "mead_deps.h"
#include "mead_interface.h"
#include "mead_log.h"
#include "mead_symbols.h"
#include "mead_tlv.h"

#include <dlfcn.h>
#include <libgen.h>
#include <link.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Which provider library stands in for which Android soname. A NULL file
// marks the sonames Mead expects from the game's own directory when no
// provider claims them; those and every other unknown soname load as stubs
// whose symbols answer with the unimplemented stub.
static const struct {
    const char *soname;
    const char *file;
} providers[] = {
    { "libc.so",          "libMeadBionic.so" },
    { "libm.so",          "libMeadBionic.so" },
    { "libdl.so",         "libMeadBionic.so" },
    { "liblog.so",        "libMeadBionic.so" },
    { "libz.so",          "libMeadBionic.so" },
    { "libstdc++.so",     "libMeadBionic.so" },
    { "libandroid.so",    "libMeadAndroid.so" },
    { "libmediandk.so",   "libMeadAndroid.so" },
    { "libjnigraphics.so","libMeadAndroid.so" },
    { "libEGL.so",        "libMeadEGL.so" },
    { "libGLESv1_CM.so",  "libMeadEGL.so" },
    { "libGLESv2.so",     "libMeadEGL.so" },
    { "libGLESv3.so",     "libMeadEGL.so" },
    { "libvulkan.so",     "libMeadVulkan.so" },
    { "libOpenSLES.so",   "libMeadOpenSLES.so" },
    { "libaaudio.so",     "libMeadOpenSLES.so" },
    { "libart.so",        "libMeadAndroid.so" },
    { "libnativehelper.so", "libMeadAndroid.so" },
    // No Android soname: listed so that mead --dex finds ART's runner.
    { "libmead_art.so",   "libMeadART.so" },
};
#define PROVIDER_COUNT (sizeof(providers) / sizeof(providers[0]))

// The registry's lock is recursive: loading a dependency loads its own
// dependencies through the same path, as DT_NEEDED is a graph.
static pthread_mutex_t lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP;
static mead_image **images;       // every image, in load order
static size_t image_count, image_space;
static void *provider_handles[PROVIDER_COUNT]; // dlopen'd, one per providers[] entry
static bool provider_tried[PROVIDER_COUNT];    // whether that dlopen has been tried
static char provider_dir[4096];   // where the providers are
static char *game_dir;            // the first game library's directory
static mead_image *adding_root;   // the library the current load began with
static void (*provider_opened)(void *handle); // once the providers have started

void mead_deps_lock(void) {
    pthread_mutex_lock(&lock);
}

void mead_deps_unlock(void) {
    pthread_mutex_unlock(&lock);
}

void mead_deps_init(void) {
    pthread_mutex_lock(&lock);
    if (!*provider_dir) {
        ssize_t length = readlink("/proc/self/exe", provider_dir, sizeof(provider_dir) - 1);
        if (length > 0) {
            provider_dir[length] = 0;
            char *slash = strrchr(provider_dir, '/');
            if (slash)
                *slash = 0;
            else
                provider_dir[0] = 0;
        }
    }
    pthread_mutex_unlock(&lock);
}

const char *mead_deps_provider_for(const char *soname) {
    for (size_t index = 0; index < sizeof(providers) / sizeof(providers[0]); index++)
        if (strcmp(providers[index].soname, soname) == 0)
            return providers[index].file;
    return NULL;
}

// The provider at `index`'s table place, dlopen'd once, whether that worked
// or not: binding asks for thousands of symbols. NULL when it cannot be
// opened (reported once).
static void *open_provider(size_t index) {
    if (!provider_tried[index]) {
        provider_tried[index] = true;
        char path[4096];
        snprintf(path, sizeof(path), "%s/%s", provider_dir, providers[index].file);
        provider_handles[index] = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!provider_handles[index]) {
            mead_trace("load", "no provider for %s: %s", providers[index].soname, dlerror());
        } else if (provider_opened) {
            // Opened after the rest have started, as by a game's dlopen of
            // libvulkan.so: it still gets its startup, once.
            bool seen = false;
            for (size_t other = 0; other < PROVIDER_COUNT; other++)
                seen = seen || (other != index && provider_handles[other] == provider_handles[index]);
            if (!seen)
                provider_opened(provider_handles[index]);
        }
    }
    return provider_handles[index];
}

// The provider standing in for `soname`, dlopen'd; NULL when none does.
// DT_NEEDED comes here, so a system soname a game needs has its provider
// loaded in order, before anything binds to it.
static void *provider_for(const char *soname) {
    for (size_t index = 0; index < PROVIDER_COUNT; index++)
        if (strcmp(providers[index].soname, soname) == 0)
            return open_provider(index);
    return NULL;
}

void *mead_deps_provider_handle(const char *soname) {
    pthread_mutex_lock(&lock);
    void *handle = provider_for(soname);
    pthread_mutex_unlock(&lock);
    return handle;
}

// A provider's own definition of a name. dlsym on a handle also searches
// what the library depends on, which for every provider means the host's C
// library: an Android caller of stat() must not end up in glibc's by way of
// a provider that never said it could take it.
static void *own_symbol(void *handle, const char *name) {
    void *symbol = dlsym(handle, name);
    if (!symbol)
        return NULL;
    struct link_map *provider = NULL, *definer = NULL;
    Dl_info info;
    if (dlinfo(handle, RTLD_DI_LINKMAP, &provider) != 0 ||
        !dladdr1(symbol, &info, (void **)&definer, RTLD_DL_LINKMAP))
        return NULL;
    return provider == definer ? symbol : NULL;
}

// The runtime's own NDK function for a name while ART runs: AOSP's
// libandroid sources on the framework's real objects (input queues and
// events, assets, configurations, native activities), which ART's
// libandroid_runtime exports as mead_ndk_<name>. ART loads it before any
// app library, and it stays loaded.
static void *runtime_ndk_symbol(const char *name) {
    static void *runtime;
    if (!runtime)
        runtime = dlopen("libandroid_runtime.so", RTLD_NOW | RTLD_NOLOAD);
    if (!runtime || name[0] != 'A')
        return NULL;
    char prefixed[256];
    if (snprintf(prefixed, sizeof(prefixed), "mead_ndk_%s", name) >= (int)sizeof(prefixed))
        return NULL;
    return dlsym(runtime, prefixed);
}

void *mead_deps_provider_symbol(const char *name) {
    pthread_mutex_lock(&lock);
    void *symbol = runtime_ndk_symbol(name);
    if (symbol) {
        pthread_mutex_unlock(&lock);
        return symbol;
    }
    void *asked = NULL; // sonames sharing a provider sit side by side
    for (size_t index = 0; index < PROVIDER_COUNT && !symbol; index++) {
        void *handle = open_provider(index);
        if (!handle || handle == asked)
            continue;
        asked = handle;
        symbol = own_symbol(handle, name);
        if (!symbol) {
            mead_provider_symbol_fn hook =
                (mead_provider_symbol_fn)dlsym(handle, MEAD_PROVIDER_SYMBOL_SYMBOL);
            if (hook)
                symbol = hook(name);
        }
    }
    pthread_mutex_unlock(&lock);
    return symbol;
}

void mead_deps_set_provider_opened(void (*callback)(void *handle)) {
    pthread_mutex_lock(&lock);
    provider_opened = callback;
    pthread_mutex_unlock(&lock);
}

void mead_deps_providers(void ***handles, const char ***files, size_t *count) {
    // Each provider opened so far, once: several sonames share a file, and
    // its startup and image hooks are to run once for it.
    static void *handles_storage[PROVIDER_COUNT];
    static const char *files_storage[PROVIDER_COUNT];
    pthread_mutex_lock(&lock);
    size_t unique = 0;
    for (size_t index = 0; index < PROVIDER_COUNT; index++) {
        if (!provider_handles[index])
            continue;
        bool repeated = false;
        for (size_t earlier = 0; earlier < unique; earlier++)
            if (handles_storage[earlier] == provider_handles[index])
                repeated = true;
        if (repeated)
            continue;
        handles_storage[unique] = provider_handles[index];
        files_storage[unique] = providers[index].file;
        unique++;
    }
    pthread_mutex_unlock(&lock);
    *handles = handles_storage;
    *files = files_storage;
    *count = unique;
}

bool mead_deps_locate(const char *name, char *path, size_t size) {
    pthread_mutex_lock(&lock);
    snprintf(path, size, "%s/%s", game_dir ? game_dir : ".", name);
    pthread_mutex_unlock(&lock);
    return access(path, R_OK) == 0;
}

// The image a soname or path names, if one is already loaded.
static mead_image *find_loaded(const char *name) {
    const char *slash = strrchr(name, '/');
    const char *as_soname = slash ? slash + 1 : name;
    for (size_t index = 0; index < image_count; index++) {
        if (strcmp(images[index]->path, name) == 0 ||
            (images[index]->soname && strcmp(images[index]->soname, as_soname) == 0))
            return images[index];
    }
    return NULL;
}

mead_image *mead_deps_add(const char *path, char **error) {
    mead_deps_init();
    pthread_mutex_lock(&lock);

    mead_image *already = find_loaded(path);
    if (already) {
        pthread_mutex_unlock(&lock);
        return already;
    }

    // The first game library's directory is where DT_NEEDED finds real
    // files: libc++_shared.so, the engine's own libraries.
    if (!game_dir) {
        char *copy = strdup(path);
        if (copy) {
            char *directory = dirname(copy);
            game_dir = strdup(directory);
            free(copy);
        }
    }

    mead_image *image = mead_image_open(path, error);
    if (!image) {
        pthread_mutex_unlock(&lock);
        return NULL;
    }
    if (!mead_symbols_setup(image, error)) {
        mead_image_destroy(image);
        pthread_mutex_unlock(&lock);
        return NULL;
    }
    mead_tlv_add(image);
    const Elf64_Dyn *soname = mead_image_dynamic(image, DT_SONAME);
    if (soname && image->strings)
        image->soname = strdup(image->strings + soname->d_un.d_val);
    if ((already = find_loaded(image->soname ? image->soname : path))) {
        mead_image_destroy(image);
        pthread_mutex_unlock(&lock);
        return already;
    }

    if (image_count == image_space) {
        size_t space = image_space ? image_space * 2 : 16;
        mead_image **grown = realloc(images, space * sizeof(*images));
        if (!grown) {
            mead_image_destroy(image);
            if (error)
                *error = NULL;
            pthread_mutex_unlock(&lock);
            return NULL;
        }
        images = grown;
        image_space = space;
    }
    images[image_count] = image;
    image->order = image_count++;

    // DT_NEEDED, in order: a real file beside the game's libraries, a
    // provider's soname, or a stub nothing more is done for — the symbols
    // it would answer with are looked for in everything else, and what
    // nothing answers binds to the unimplemented stub.
    size_t needed = 0;
    for (const Elf64_Dyn *entry = image->dynamic; entry->d_tag != DT_NULL; entry++)
        if (entry->d_tag == DT_NEEDED)
            needed++;
    image->needed = calloc(needed ? needed : 1, sizeof(*image->needed));
    if (!image->needed) {
        pthread_mutex_unlock(&lock);
        mead_image_destroy(image); // and its registry slot
        image_count--;
        if (error)
            *error = NULL;
        return NULL;
    }
    bool outermost = !adding_root;
    if (outermost)
        adding_root = image;
    image->root = adding_root;
    size_t at = 0;
    for (const Elf64_Dyn *entry = image->dynamic; entry->d_tag != DT_NULL; entry++) {
        if (entry->d_tag != DT_NEEDED)
            continue;
        const char *name = image->strings + entry->d_un.d_val;
        char file[4096];
        snprintf(file, sizeof(file), "%s/%s", game_dir ? game_dir : ".", name);
        mead_image *dependency = NULL;
        char *why = NULL;
        if (access(file, R_OK) == 0)
            dependency = mead_deps_add(file, &why);
        else if (provider_for(name))
            mead_trace("load", "%s needs %s, answered by a provider", image->path, name);
        else
            mead_trace("load", "%s needs %s, which no file or provider answers; its symbols become stubs",
                       image->path, name);
        if (why)
            mead_trace("load", "%s needs %s, which cannot be loaded: %s", image->path, name, why);
        free(why);
        if (dependency)
            image->needed[at++] = dependency;
    }
    image->needed_count = at;
    if (outermost)
        adding_root = NULL;

    mead_trace("load", "loaded %s (%s)%s", image->path, image->soname ? image->soname : "no soname",
               image->needed_count ? "" : ", needing nothing");
    pthread_mutex_unlock(&lock);
    return image;
}

mead_image *const *mead_deps_images(size_t *count) {
    if (count)
        *count = image_count;
    return images;
}

mead_image *mead_deps_image_for(const void *address) {
    for (size_t index = 0; index < image_count; index++) {
        const mead_image *image = images[index];
        for (uint16_t segment = 0; segment < image->phnum; segment++) {
            const Elf64_Phdr *at = (const Elf64_Phdr *)
                ((const char *)image->phdr + (size_t)segment * image->phentsize);
            if (at->p_type != PT_LOAD)
                continue;
            if ((uint64_t)address >= image->load_bias + at->p_vaddr &&
                (uint64_t)address < image->load_bias + at->p_vaddr + at->p_memsz)
                return images[index];
        }
    }
    return NULL;
}

// The search: `from` itself, breadth first through what it needs, and then
// — unless only its own tree is wanted, as for dlsym on a handle — everything
// else in load order. An image is marked as it joins the queue, so a diamond
// of dependencies queues it once and the queue can hold every image.
static const Elf64_Sym *search(const mead_image *from, const char *name, const mead_image **owner,
                               bool tree_only) {
    size_t count = image_count;
    if (count == 0)
        return NULL;
    bool *visited = calloc(count, sizeof(*visited));
    const mead_image **queue = malloc(count * sizeof(*queue));
    const Elf64_Sym *symbol = NULL;
    if (!visited || !queue)
        goto done;

    size_t head = 0, tail = 0;
    if (from && from->order < count) {
        visited[from->order] = true;
        queue[tail++] = from;
    }
    while (head < tail) {
        const mead_image *image = queue[head++];
        const Elf64_Sym *found = mead_symbols_find(image, name);
        if (found && found->st_shndx != SHN_UNDEF) {
            symbol = found;
            if (owner)
                *owner = image;
            goto done;
        }
        for (size_t index = 0; index < image->needed_count; index++) {
            const mead_image *needed = image->needed[index];
            if (!visited[needed->order]) {
                visited[needed->order] = true;
                queue[tail++] = needed;
            }
        }
    }

    for (size_t index = 0; index < count && !tree_only; index++) {
        if (visited[index])
            continue;
        const Elf64_Sym *found = mead_symbols_find(images[index], name);
        if (found && found->st_shndx != SHN_UNDEF) {
            symbol = found;
            if (owner)
                *owner = images[index];
            goto done;
        }
    }

done:
    free(visited);
    free(queue);
    return symbol;
}

const Elf64_Sym *mead_deps_find_symbol(const mead_image *from, const char *name,
                                       const mead_image **owner) {
    if (owner)
        *owner = NULL;
    pthread_mutex_lock(&lock);
    const Elf64_Sym *symbol = search(from, name, owner, false);
    pthread_mutex_unlock(&lock);
    return symbol;
}

const Elf64_Sym *mead_deps_find_in_tree(const mead_image *from, const char *name,
                                        const mead_image **owner) {
    if (owner)
        *owner = NULL;
    pthread_mutex_lock(&lock);
    const Elf64_Sym *symbol = search(from, name, owner, true);
    pthread_mutex_unlock(&lock);
    return symbol;
}

void *mead_deps_lookup(const char *name) {
    const mead_image *owner = NULL;
    const Elf64_Sym *symbol = mead_deps_find_symbol(NULL, name, &owner);
    if (symbol)
        return mead_image_symbol_address(owner, symbol);
    pthread_mutex_lock(&lock);
    void *address = mead_deps_provider_symbol(name);
    pthread_mutex_unlock(&lock);
    return address;
}

void *mead_deps_lookup_after(const void *caller, const char *name) {
    pthread_mutex_lock(&lock);
    mead_image *in = mead_deps_image_for(caller);
    for (size_t index = in ? in->order + 1 : 0; index < image_count; index++) {
        const Elf64_Sym *symbol = mead_symbols_find(images[index], name);
        if (symbol && symbol->st_shndx != SHN_UNDEF) {
            void *address = mead_image_symbol_address(images[index], symbol);
            pthread_mutex_unlock(&lock);
            return address;
        }
    }
    void *address = mead_deps_provider_symbol(name);
    pthread_mutex_unlock(&lock);
    return address;
}
