#define _GNU_SOURCE
#include "mead_dl_bio.h"

#include <dlfcn.h>
#include <elf.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static mead_dl_bio_loader mead_loader;

void mead_dl_bio_install(const mead_dl_bio_loader *loader) {
    mead_loader = *loader;
}

void mead_dl_bio_install_functions(void *(*open)(const char *name, int flags),
                                   void *(*sym)(void *handle, const char *name, const void *caller),
                                   int (*close)(void *handle), const char *(*error)(void)) {
    mead_loader = (mead_dl_bio_loader){ .open = open, .sym = sym, .close = close, .error = error };
}

// Directories for libraries asked for by name, set up before ART starts.
enum { SEARCH_DIRECTORIES = 8 };
static char *search_directories[SEARCH_DIRECTORIES];
static size_t search_directory_count;

void mead_dl_bio_add_search_directory(const char *directory) {
    if (search_directory_count < SEARCH_DIRECTORIES)
        search_directories[search_directory_count++] = strdup(directory);
}

// A library asked for by name, from the search directories first.
static void *open_by_name(const char *name, int flag) {
    for (size_t index = 0; index < search_directory_count; index++) {
        char path[4096];
        if (snprintf(path, sizeof(path), "%s/%s", search_directories[index], name) >= (int)sizeof(path))
            continue;
        if (access(path, F_OK) == 0)
            return dlopen(path, flag);
    }
    return dlopen(name, flag);
}

// A handle remembers which linker opened it.
typedef struct handle {
    bool host;
    void *opened;
} handle;

// Which linker the last failure came from, per thread, as dlerror is.
static __thread bool error_from_mead;
static __thread const char *error_message;

static void fail(bool from_mead, const char *message) {
    error_from_mead = from_mead;
    error_message = message;
}

// The file offset of a virtual address, through the PT_LOAD that maps it.
static bool offset_of(const Elf64_Phdr *headers, size_t count, uint64_t address, uint64_t *offset) {
    for (size_t index = 0; index < count; index++) {
        const Elf64_Phdr *header = &headers[index];
        if (header->p_type == PT_LOAD && address >= header->p_vaddr && address < header->p_vaddr + header->p_filesz) {
            *offset = address - header->p_vaddr + header->p_offset;
            return true;
        }
    }
    return false;
}

bool mead_dl_bio_is_bionic_library(const char *path) {
    int descriptor = open(path, O_RDONLY | O_CLOEXEC);
    if (descriptor < 0)
        return false;
    struct stat status;
    bool bionic = false;
    if (fstat(descriptor, &status) == 0 && (size_t)status.st_size >= sizeof(Elf64_Ehdr)) {
        size_t size = (size_t)status.st_size;
        const uint8_t *bytes = mmap(NULL, size, PROT_READ, MAP_PRIVATE, descriptor, 0);
        if (bytes != MAP_FAILED) {
            const Elf64_Ehdr *elf = (const Elf64_Ehdr *)bytes;
            if (memcmp(elf->e_ident, ELFMAG, SELFMAG) == 0 && elf->e_ident[EI_CLASS] == ELFCLASS64 &&
                elf->e_phoff + (uint64_t)elf->e_phnum * sizeof(Elf64_Phdr) <= size) {
                const Elf64_Phdr *headers = (const Elf64_Phdr *)(bytes + elf->e_phoff);
                const Elf64_Dyn *dynamic = NULL;
                size_t dynamic_count = 0;
                for (size_t index = 0; index < elf->e_phnum; index++)
                    if (headers[index].p_type == PT_DYNAMIC && headers[index].p_offset + headers[index].p_filesz <= size) {
                        dynamic = (const Elf64_Dyn *)(bytes + headers[index].p_offset);
                        dynamic_count = headers[index].p_filesz / sizeof(Elf64_Dyn);
                    }
                uint64_t strings = 0;
                bool have_strings = false;
                for (size_t index = 0; dynamic && index < dynamic_count && dynamic[index].d_tag != DT_NULL; index++)
                    if (dynamic[index].d_tag == DT_STRTAB)
                        have_strings = offset_of(headers, elf->e_phnum, dynamic[index].d_un.d_ptr, &strings);
                for (size_t index = 0; have_strings && index < dynamic_count && dynamic[index].d_tag != DT_NULL; index++) {
                    if (dynamic[index].d_tag != DT_NEEDED)
                        continue;
                    uint64_t name = strings + dynamic[index].d_un.d_val;
                    if (name < size && strnlen((const char *)bytes + name, size - name) < size - name &&
                        strcmp((const char *)bytes + name, "libc.so") == 0) {
                        bionic = true;
                        break;
                    }
                }
            }
            munmap((void *)bytes, size);
        }
    }
    close(descriptor);
    return bionic;
}

void dl_parse_library_path(const char *path, char *delim) {
    (void)path;
    (void)delim;
}

void *bionic_dlopen(const char *filename, int flag) {
    // A name without a path is a host library ART asks for by name
    // (libjavacore.so), unless the system has none by that name.
    bool host = filename == NULL || !strchr(filename, '/') || !mead_dl_bio_is_bionic_library(filename);
    void *opened = NULL;
    if (host) {
        opened = filename && !strchr(filename, '/') ? open_by_name(filename, flag) : dlopen(filename, flag);
        if (!opened && filename && !strchr(filename, '/') && mead_loader.open) {
            dlerror();
            host = false;
        } else if (!opened) {
            fail(false, dlerror());
            return NULL;
        }
    }
    if (!host) {
        if (!mead_loader.open) {
            fail(false, "a bionic library, with no loader for it");
            return NULL;
        }
        opened = mead_loader.open(filename, flag);
        if (!opened) {
            fail(true, NULL);
            return NULL;
        }
    }
    handle *made = malloc(sizeof(*made));
    if (!made) {
        if (host)
            dlclose(opened);
        else
            mead_loader.close(opened);
        fail(false, "out of memory");
        return NULL;
    }
    made->host = host;
    made->opened = opened;
    return made;
}

__attribute__((noinline)) void *bionic_dlsym(void *opaque, const char *symbol) {
    handle *found = opaque;
    if (!found) {
        fail(false, "a null handle");
        return NULL;
    }
    void *address = found->host ? dlsym(found->opened, symbol)
                                : mead_loader.sym(found->opened, symbol, __builtin_return_address(0));
    if (!address)
        fail(!found->host, found->host ? dlerror() : NULL);
    return address;
}

int bionic_dlclose(void *opaque) {
    handle *found = opaque;
    if (!found)
        return -1;
    int result = found->host ? dlclose(found->opened) : mead_loader.close(found->opened);
    free(found);
    return result;
}

const char *bionic_dlerror(void) {
    const char *message = error_from_mead && mead_loader.error ? mead_loader.error() : error_message;
    error_message = NULL;
    error_from_mead = false;
    return message;
}
