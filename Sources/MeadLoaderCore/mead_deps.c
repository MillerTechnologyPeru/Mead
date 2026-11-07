#define _GNU_SOURCE
#include "mead_deps.h"
#include "mead_log.h"
#include "mead_symbols.h"

#include <dlfcn.h>
#include <libgen.h>
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
    { "libart.so",        "libMeadJNI.so" },
};

// The registry's lock is recursive: loading a dependency loads its own
// dependencies through the same path, as DT_NEEDED is a graph.
static pthread_mutex_t lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP;
static mead_image **images;       // every image, in load order
static size_t image_count, image_space;
static void **provider_handles;   // dlopen'd, one per providers[] entry
static char provider_dir[4096];   // where the providers are
static char *game_dir;            // the first game library's directory

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

// The provider at `index`'s table place, dlopen'd once. NULL when it has no
// file or cannot be opened (reported once).
static void *open_provider(size_t index) {
    if (!provider_handles) {
        provider_handles = calloc(sizeof(providers) / sizeof(providers[0]),
                                  sizeof(*provider_handles));
        if (!provider_handles)
            return NULL;
    }
    if (!provider_handles[index] && providers[index].file) {
        char path[4096];
        snprintf(path, sizeof(path), "%s/%s", provider_dir, providers[index].file);
        provider_handles[index] = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!provider_handles[index])
            mead_trace("load", "no provider for %s: %s", providers[index].soname, dlerror());
    }
    return provider_handles[index];
}

// The provider standing in for `soname`, dlopen'd; NULL when none does.
// DT_NEEDED comes here, so a system soname a game needs has its provider
// loaded in order, before anything binds to it.
static void *provider_for(const char *soname) {
    for (size_t index = 0; index < sizeof(providers) / sizeof(providers[0]); index++)
        if (strcmp(providers[index].soname, soname) == 0)
            return open_provider(index);
    return NULL;
}

void *mead_deps_provider_symbol(const char *name) {
    pthread_mutex_lock(&lock);
    for (size_t index = 0; index < sizeof(providers) / sizeof(providers[0]); index++) {
        if (!open_provider(index))
            continue;
        void *symbol = dlsym(provider_handles[index], name);
        if (symbol) {
            pthread_mutex_unlock(&lock);
            return symbol;
        }
    }
    pthread_mutex_unlock(&lock);
    return NULL;
}

void mead_deps_providers(void ***handles, const char ***files, size_t *count) {
    // The provider table, opened or not; callers skip what they are not
    // given (a NULL handle is a provider that has not been needed yet).
    static void *handles_storage[sizeof(providers) / sizeof(providers[0])];
    static const char *files_storage[sizeof(providers) / sizeof(providers[0])];
    pthread_mutex_lock(&lock);
    for (size_t index = 0; index < sizeof(providers) / sizeof(providers[0]); index++) {
        if (provider_handles)
            handles_storage[index] = provider_handles[index];
        else
            handles_storage[index] = NULL;
        files_storage[index] = providers[index].file;
    }
    pthread_mutex_unlock(&lock);
    *handles = handles_storage;
    *files = files_storage;
    *count = sizeof(providers) / sizeof(providers[0]);
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
        free(why);
        if (dependency)
            image->needed[at++] = dependency;
    }
    image->needed_count = at;

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

// The search breadth first from what `from` needs, then everything. The
// two passes share the visited marks, an index into the image list.
static const Elf64_Sym *search(const mead_image *from, const char *name, const mead_image **owner) {
    size_t count = image_count;
    if (count == 0)
        return NULL;
    bool *visited = calloc(count, sizeof(*visited));
    if (!visited)
        return NULL;

    // Breadth first over what `from` needs.
    const mead_image **queue = malloc(count * sizeof(*queue));
    if (queue) {
        size_t head = 0, tail = 0;
        if (from && from->order < count) {
            visited[from->order] = true;
            for (size_t index = 0; index < from->needed_count; index++)
                if (!visited[from->needed[index]->order])
                    queue[tail++] = from->needed[index];
        }
        while (head < tail) {
            const mead_image *image = queue[head++];
            visited[image->order] = true;
            const Elf64_Sym *symbol = mead_symbols_find(image, name);
            if (symbol && symbol->st_shndx != SHN_UNDEF) {
                if (owner)
                    *owner = image;
                free(visited);
                free(queue);
                return symbol;
            }
            for (size_t index = 0; index < image->needed_count; index++)
                if (!visited[image->needed[index]->order])
                    queue[tail++] = image->needed[index];
        }
    }
    free(queue);

    // Then everything in load order.
    for (size_t index = 0; index < count; index++) {
        if (visited[index])
            continue;
        const Elf64_Sym *symbol = mead_symbols_find(images[index], name);
        if (symbol && symbol->st_shndx != SHN_UNDEF) {
            if (owner)
                *owner = images[index];
            free(visited);
            return symbol;
        }
    }
    free(visited);
    return NULL;
}

const Elf64_Sym *mead_deps_find_symbol(const mead_image *from, const char *name,
                                       const mead_image **owner) {
    if (owner)
        *owner = NULL;
    pthread_mutex_lock(&lock);
    const Elf64_Sym *symbol = search(from, name, owner);
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
