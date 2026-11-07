#define _GNU_SOURCE
#include "mead_image.h"
#include "mead_log.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

// Says why an image cannot be loaded and returns NULL, so open's failures
// are one line each.
static mead_image *failure(char **error, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    if (error) {
        if (vasprintf(error, format, arguments) < 0)
            *error = NULL;
    }
    va_end(arguments);
    return NULL;
}

// Reads into `buffer`, or fails. Short reads mean a truncated library.
static bool read_all(int fd, void *buffer, size_t size, off_t offset, char **error) {
    char *into = buffer;
    while (size > 0) {
        ssize_t read_ = pread(fd, into, size, offset);
        if (read_ < 0) {
            failure(error, "cannot read: %s", strerror(errno));
            return false;
        }
        if (read_ == 0) {
            failure(error, "the file is too short");
            return false;
        }
        into += read_;
        size -= (size_t)read_;
        offset += read_;
    }
    return true;
}

mead_image *mead_image_open(const char *path, char **error) {
    mead_image *image = calloc(1, sizeof(*image));
    if (!image)
        return failure(error, "out of memory");
    image->fd = -1;

    image->path = strdup(path);
    if (!image->path)
        goto out_of_memory;

    image->fd = open(path, O_RDONLY | O_CLOEXEC);
    if (image->fd < 0)
        return failure(error, "cannot open: %s", strerror(errno));

    // The ELF header and program headers, read before anything is mapped.
    Elf64_Ehdr header;
    if (!read_all(image->fd, &header, sizeof(header), 0, error))
        goto failed;
    if (memcmp(header.e_ident, ELFMAG, SELFMAG) != 0 || header.e_ident[EI_CLASS] != ELFCLASS64)
        return failure(error, "not an ELF 64-bit file");
    if (header.e_ident[EI_DATA] != ELFDATA2LSB || header.e_machine != EM_AARCH64)
        return failure(error, "not an arm64 file");
    if (header.e_type != ET_DYN)
        return failure(error, "not a shared library");
    if (header.e_phentsize != sizeof(Elf64_Phdr) || header.e_phnum == 0)
        return failure(error, "strange program headers");

    image->phentsize = header.e_phentsize;
    image->phnum = header.e_phnum;
    image->phdr = malloc((size_t)header.e_phnum * header.e_phentsize);
    if (!image->phdr)
        goto out_of_memory;
    if (!read_all(image->fd, (void *)image->phdr, (size_t)header.e_phnum * header.e_phentsize,
                  header.e_phoff, error))
        goto failed;

    // Where the LOAD segments fall, and how strictly they are aligned.
    uint64_t lowest = UINT64_MAX, highest = 0;
    for (uint16_t index = 0; index < image->phnum; index++) {
        const Elf64_Phdr *segment = (const Elf64_Phdr *)
            ((const char *)image->phdr + (size_t)index * image->phentsize);
        if (segment->p_type != PT_LOAD)
            continue;
        if (segment->p_align > image->alignment)
            image->alignment = segment->p_align;
        uint64_t start = segment->p_vaddr & ~(segment->p_align - 1);
        uint64_t end = (segment->p_vaddr + segment->p_memsz + segment->p_align - 1) & ~(segment->p_align - 1);
        if (start < lowest)
            lowest = start;
        if (end > highest)
            highest = end;
        if ((segment->p_offset & (segment->p_align - 1)) != (segment->p_vaddr & (segment->p_align - 1)))
            return failure(error, "a segment is not congruent to its file offset");
    }
    if (lowest == UINT64_MAX || highest < lowest)
        return failure(error, "no loadable segments");

    // Reserve the span, aligned as strictly as the strictest segment: a
    // 16 KB-aligned NDK library stays 16 KB-aligned on a 4 KB-page host.
    long page = sysconf(_SC_PAGESIZE);
    if (image->alignment < (uint64_t)page)
        image->alignment = (uint64_t)page;
    size_t span = (size_t)(highest - lowest);
    void *reserved = mmap(NULL, span + image->alignment, PROT_NONE,
                          MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (reserved == MAP_FAILED)
        return failure(error, "cannot reserve %zu bytes: %s", span, strerror(errno));
    uint64_t base = ((uint64_t)reserved + image->alignment - 1) & ~(image->alignment - 1);
    if ((uint64_t)reserved < base)
        munmap(reserved, (size_t)(base - (uint64_t)reserved));
    if (base + span < (uint64_t)reserved + span + image->alignment)
        munmap((void *)(base + span),
               (size_t)((uint64_t)reserved + span + image->alignment - base - span));
    image->load_bias = base - lowest;

    // Map each segment readable and writable for now; relocation comes
    // before mead_image_protect puts execute and drops write where they
    // belong. What memsz promises past filesz is zeroed to the page, and
    // the rest is mapped anonymous.
    for (uint16_t index = 0; index < image->phnum; index++) {
        const Elf64_Phdr *segment =
            (const Elf64_Phdr *)((const char *)image->phdr + (size_t)index * image->phentsize);
        if (segment->p_type != PT_LOAD)
            continue;
        uint64_t file_start = segment->p_vaddr & ~((uint64_t)page - 1);
        uint64_t file_end = (segment->p_vaddr + segment->p_filesz + (uint64_t)page - 1) & ~((uint64_t)page - 1);
        void *at = mead_image_address(image, file_start);
        off_t offset = (off_t)(segment->p_offset & ~((uint64_t)page - 1));
        if (file_end > file_start &&
            mmap(at, (size_t)(file_end - file_start), PROT_READ | PROT_WRITE,
                 MAP_FIXED | MAP_PRIVATE, image->fd, offset) == MAP_FAILED)
            return failure(error, "cannot map a segment: %s", strerror(errno));
        uint64_t zero_from = segment->p_vaddr + segment->p_filesz;
        if (file_end > zero_from)
            memset(mead_image_address(image, zero_from), 0, (size_t)(file_end - zero_from));
        uint64_t anon_from = (file_end + (uint64_t)page - 1) & ~((uint64_t)page - 1);
        uint64_t anon_to = segment->p_vaddr + segment->p_memsz;
        if (anon_to > anon_from &&
            mmap(mead_image_address(image, anon_from), (size_t)(anon_to - anon_from),
                 PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) == MAP_FAILED)
            return failure(error, "cannot map a segment's zeros: %s", strerror(errno));
    }
    image->mapped = true;
    mead_trace("load", "mapped %s at %p (bias 0x%lx, align %lu)",
               path, mead_image_address(image, lowest), image->load_bias, image->alignment);

    // The dynamic table, from the mapped image now that it is in memory.
    const Elf64_Phdr *dynamic = mead_image_segment(image, PT_DYNAMIC);
    if (dynamic)
        image->dynamic = mead_image_address(image, dynamic->p_vaddr);
    return image;

out_of_memory:
    mead_image_destroy(image);
    return failure(error, "out of memory");
failed:
    mead_image_destroy(image);
    return NULL;
}

void mead_image_destroy(mead_image *image) {
    if (!image)
        return;
    free(image->path);
    free(image->soname);
    free((void *)image->phdr);
    free(image->needed);
    if (image->fd >= 0)
        close(image->fd);
    free(image);
}

const Elf64_Phdr *mead_image_segment(const mead_image *image, uint32_t type) {
    for (uint16_t index = 0; index < image->phnum; index++) {
        const Elf64_Phdr *segment =
            (const Elf64_Phdr *)((const char *)image->phdr + (size_t)index * image->phentsize);
        if (segment->p_type == type)
            return segment;
    }
    return NULL;
}

const Elf64_Dyn *mead_image_dynamic(const mead_image *image, uint64_t tag) {
    if (!image->dynamic)
        return NULL;
    for (const Elf64_Dyn *entry = image->dynamic; entry->d_tag != DT_NULL; entry++)
        if (entry->d_tag == tag)
            return entry;
    return NULL;
}

void *mead_image_symbol_address(const mead_image *image, const Elf64_Sym *symbol) {
    if (symbol->st_shndx == SHN_UNDEF)
        return NULL;
    if (symbol->st_shndx == SHN_ABS)
        return (void *)(uintptr_t)symbol->st_value;
    return mead_image_address(image, symbol->st_value);
}

void mead_image_protect(mead_image *image) {
    if (!image->mapped || image->hardened)
        return;
    long page = sysconf(_SC_PAGESIZE);
    for (uint16_t index = 0; index < image->phnum; index++) {
        const Elf64_Phdr *segment =
            (const Elf64_Phdr *)((const char *)image->phdr + (size_t)index * image->phentsize);
        if (segment->p_type != PT_LOAD)
            continue;
        int prot = (segment->p_flags & PF_R ? PROT_READ : 0) |
                   (segment->p_flags & PF_W ? PROT_WRITE : 0) |
                   (segment->p_flags & PF_X ? PROT_EXEC : 0);
        if (prot == 0)
            prot = PROT_READ;
        uint64_t from = segment->p_vaddr & ~((uint64_t)page - 1);
        uint64_t to = (segment->p_vaddr + segment->p_memsz + (uint64_t)page - 1) & ~((uint64_t)page - 1);
        if (to > from)
            mprotect(mead_image_address(image, from), (size_t)(to - from), prot);
    }
    image->hardened = true;
}
