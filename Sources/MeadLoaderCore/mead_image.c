#define _GNU_SOURCE
#include "mead_image.h"
#include "mead_log.h"
#include "mead_tlv.h"

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

// A LOAD segment's alignment: its p_align, where 0 and 1 both mean none.
static uint64_t alignment_of(const Elf64_Phdr *segment) {
    return segment->p_align > 1 ? segment->p_align : 1;
}

// The i'th program header.
static const Elf64_Phdr *segment_at(const mead_image *image, uint16_t index) {
    return (const Elf64_Phdr *)((const char *)image->phdr + (size_t)index * image->phentsize);
}

// The most a library's segments may span, and the strictest alignment one
// may ask for: far past any real library, and small enough that the sums
// below cannot wrap.
#define MEAD_IMAGE_MAX_SPAN (1ull << 36)
#define MEAD_IMAGE_MAX_ALIGNMENT (1ull << 30)

mead_image *mead_image_open(const char *path, char **error) {
    mead_image *image = calloc(1, sizeof(*image));
    if (!image)
        return failure(error, "out of memory");
    image->fd = -1;

    image->path = strdup(path);
    if (!image->path) {
        failure(error, "out of memory");
        goto failed;
    }

    image->fd = open(path, O_RDONLY | O_CLOEXEC);
    if (image->fd < 0) {
        failure(error, "cannot open: %s", strerror(errno));
        goto failed;
    }
    struct stat status;
    if (fstat(image->fd, &status) != 0 || status.st_size < 0) {
        failure(error, "cannot measure: %s", strerror(errno));
        goto failed;
    }
    uint64_t file_size = (uint64_t)status.st_size;

    // The ELF header and program headers, read before anything is mapped.
    Elf64_Ehdr header;
    if (!read_all(image->fd, &header, sizeof(header), 0, error))
        goto failed;
    const char *wrong = NULL;
    if (memcmp(header.e_ident, ELFMAG, SELFMAG) != 0 || header.e_ident[EI_CLASS] != ELFCLASS64)
        wrong = "not an ELF 64-bit file";
    else if (header.e_ident[EI_DATA] != ELFDATA2LSB || header.e_machine != EM_AARCH64)
        wrong = "not an arm64 file";
    else if (header.e_type != ET_DYN)
        wrong = "not a shared library";
    else if (header.e_phentsize != sizeof(Elf64_Phdr) || header.e_phnum == 0)
        wrong = "strange program headers";
    else if (header.e_phoff > file_size ||
             (uint64_t)header.e_phnum * header.e_phentsize > file_size - header.e_phoff)
        wrong = "the program headers are past the end of the file";
    if (wrong) {
        failure(error, "%s", wrong);
        goto failed;
    }

    image->phentsize = header.e_phentsize;
    image->phnum = header.e_phnum;
    image->phdr = malloc((size_t)header.e_phnum * header.e_phentsize);
    if (!image->phdr) {
        failure(error, "out of memory");
        goto failed;
    }
    if (!read_all(image->fd, (void *)image->phdr, (size_t)header.e_phnum * header.e_phentsize,
                  (off_t)header.e_phoff, error))
        goto failed;

    // Where the LOAD segments fall, and how strictly they are aligned. Each
    // is checked before its numbers are used: its alignment is a power of
    // two, its memory holds its file bytes, those bytes are in the file,
    // and nothing wraps. A segment is mapped by the host's pages, so its
    // span is rounded to those when its own alignment is finer.
    uint64_t page = (uint64_t)sysconf(_SC_PAGESIZE);
    uint64_t lowest = UINT64_MAX, highest = 0;
    for (uint16_t index = 0; index < image->phnum; index++) {
        const Elf64_Phdr *segment = segment_at(image, index);
        if (segment->p_type != PT_LOAD)
            continue;
        uint64_t alignment = alignment_of(segment);
        if ((alignment & (alignment - 1)) != 0 || alignment > MEAD_IMAGE_MAX_ALIGNMENT) {
            failure(error, "a segment's alignment is not a power of two");
            goto failed;
        }
        if (segment->p_filesz > segment->p_memsz) {
            failure(error, "a segment has more in the file than in memory");
            goto failed;
        }
        if (segment->p_offset > file_size || segment->p_filesz > file_size - segment->p_offset) {
            failure(error, "a segment is past the end of the file");
            goto failed;
        }
        if (segment->p_memsz > MEAD_IMAGE_MAX_SPAN || segment->p_vaddr > MEAD_IMAGE_MAX_SPAN) {
            failure(error, "a segment is too far or too large");
            goto failed;
        }
        if (alignment < page)
            alignment = page;
        if (alignment > image->alignment)
            image->alignment = alignment;
        if ((segment->p_offset & (alignment_of(segment) - 1)) != (segment->p_vaddr & (alignment_of(segment) - 1)) ||
            (segment->p_offset & (page - 1)) != (segment->p_vaddr & (page - 1))) {
            failure(error, "a segment is not congruent to its file offset");
            goto failed;
        }
        uint64_t start = segment->p_vaddr & ~(alignment - 1);
        uint64_t end = (segment->p_vaddr + segment->p_memsz + alignment - 1) & ~(alignment - 1);
        if (start < lowest)
            lowest = start;
        if (end > highest)
            highest = end;
    }
    if (lowest == UINT64_MAX || highest <= lowest) {
        failure(error, "no loadable segments");
        goto failed;
    }
    if (highest - lowest > MEAD_IMAGE_MAX_SPAN) {
        failure(error, "its segments span too much");
        goto failed;
    }

    // Reserve the span, aligned as strictly as the strictest segment: a
    // 16 KB-aligned NDK library stays 16 KB-aligned on a 4 KB-page host.
    size_t span = (size_t)(highest - lowest);
    void *reserved = mmap(NULL, span + image->alignment, PROT_NONE,
                          MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (reserved == MAP_FAILED) {
        failure(error, "cannot reserve %zu bytes: %s", span, strerror(errno));
        goto failed;
    }
    uint64_t base = ((uint64_t)reserved + image->alignment - 1) & ~(image->alignment - 1);
    if ((uint64_t)reserved < base)
        munmap(reserved, (size_t)(base - (uint64_t)reserved));
    if (base + span < (uint64_t)reserved + span + image->alignment)
        munmap((void *)(base + span),
               (size_t)((uint64_t)reserved + span + image->alignment - base - span));
    image->load_bias = base - lowest;
    image->mapping = (void *)base;
    image->mapping_size = span;

    // Map each segment readable and writable for now; relocation comes
    // before mead_image_protect puts execute and drops write where they
    // belong. What memsz promises past filesz is zeroed to the page, and
    // the rest is mapped anonymous.
    for (uint16_t index = 0; index < image->phnum; index++) {
        const Elf64_Phdr *segment = segment_at(image, index);
        if (segment->p_type != PT_LOAD)
            continue;
        uint64_t file_start = segment->p_vaddr & ~(page - 1);
        uint64_t file_end = (segment->p_vaddr + segment->p_filesz + page - 1) & ~(page - 1);
        void *at = mead_image_address(image, file_start);
        off_t offset = (off_t)(segment->p_offset & ~(page - 1));
        if (file_end > file_start &&
            mmap(at, (size_t)(file_end - file_start), PROT_READ | PROT_WRITE,
                 MAP_FIXED | MAP_PRIVATE, image->fd, offset) == MAP_FAILED) {
            failure(error, "cannot map a segment: %s", strerror(errno));
            goto failed;
        }
        // The file's last page is whole in memory, zeros past the file's
        // end: every page mapped holds a byte checked to be in the file,
        // or the page the segment's offset is in.
        uint64_t zero_from = segment->p_vaddr + segment->p_filesz;
        if (file_end > zero_from)
            memset(mead_image_address(image, zero_from), 0, (size_t)(file_end - zero_from));
        uint64_t anon_from = file_end;
        uint64_t anon_to = (segment->p_vaddr + segment->p_memsz + page - 1) & ~(page - 1);
        if (anon_to > anon_from &&
            mmap(mead_image_address(image, anon_from), (size_t)(anon_to - anon_from),
                 PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) == MAP_FAILED) {
            failure(error, "cannot map a segment's zeros: %s", strerror(errno));
            goto failed;
        }
    }
    image->mapped = true;
    mead_trace("load", "mapped %s at %p (bias 0x%lx, align %lu)",
               path, mead_image_address(image, lowest), image->load_bias, image->alignment);

    // The dynamic table, from the mapped image now that it is in memory:
    // inside a segment, and ended by a DT_NULL there, so that walking it
    // to its end never leaves the image.
    const Elf64_Phdr *dynamic = mead_image_segment(image, PT_DYNAMIC);
    if (dynamic) {
        // Aligned as its entries are read, like every table below.
        const Elf64_Dyn *table = dynamic->p_vaddr % 8 == 0
            ? mead_image_range(image, dynamic->p_vaddr, dynamic->p_memsz) : NULL;
        size_t count = (size_t)(dynamic->p_memsz / sizeof(Elf64_Dyn));
        bool ended = false;
        for (size_t index = 0; table && index < count && !ended; index++)
            ended = table[index].d_tag == DT_NULL;
        if (!ended) {
            failure(error, "its dynamic table is outside its segments, misaligned or has no end");
            goto failed;
        }
        image->dynamic = table;
    }

    // What the other program headers describe is in the image too: the
    // thread-local storage's initial values, and the region made read-only
    // after relocation.
    const Elf64_Phdr *tls = mead_image_segment(image, PT_TLS);
    if (tls && (tls->p_filesz > tls->p_memsz ||
                (tls->p_filesz > 0 && !mead_image_range(image, tls->p_vaddr, tls->p_filesz)) ||
                (tls->p_align & (tls->p_align - 1)) != 0)) {
        failure(error, "its thread-local storage is outside its segments");
        goto failed;
    }
    // RELRO's size is rounded to a page by the linker, past its segment's
    // end, so it is held to the image's span: what gets protected is the
    // image's own memory.
    const Elf64_Phdr *relro = mead_image_segment(image, PT_GNU_RELRO);
    if (relro && relro->p_memsz > 0 &&
        (relro->p_vaddr < lowest || relro->p_vaddr >= highest ||
         relro->p_memsz > highest - relro->p_vaddr)) {
        failure(error, "its RELRO region is outside the image");
        goto failed;
    }
    return image;

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
    if (image->mapping)
        munmap(image->mapping, image->mapping_size);
    if (image->fd >= 0)
        close(image->fd);
    free(image);
}

uint64_t mead_image_room(const mead_image *image, uint64_t vaddr) {
    if (!image->mapping)
        return 0;
    for (uint16_t index = 0; index < image->phnum; index++) {
        const Elf64_Phdr *segment = segment_at(image, index);
        if (segment->p_type == PT_LOAD && vaddr >= segment->p_vaddr &&
            vaddr - segment->p_vaddr < segment->p_memsz)
            return segment->p_memsz - (vaddr - segment->p_vaddr);
    }
    return 0;
}

void *mead_image_range(const mead_image *image, uint64_t vaddr, uint64_t size) {
    uint64_t room = mead_image_room(image, vaddr);
    if (room == 0 || size > room)
        return NULL;
    return mead_image_address(image, vaddr);
}

const char *mead_image_string(const mead_image *image, uint64_t offset) {
    if (!image->strings || offset >= image->strings_size)
        return NULL;
    return image->strings + offset;
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
    if (ELF64_ST_TYPE(symbol->st_info) == STT_TLS) {
        // A thread-local symbol in an image with no thread-local storage
        // (or none laid out yet) names nothing.
        char *block = mead_tlv_block(image);
        return block ? block + symbol->st_value : NULL;
    }
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
        if (to > from && mprotect(mead_image_address(image, from), (size_t)(to - from), prot) != 0)
            mead_fatal("cannot protect a segment of %s: %s", image->path, strerror(errno));
    }
    // RELRO, read-only once relocated, as Android's linker leaves it
    // (phdr_table_protect_gnu_relro): from its first page through the page
    // its end falls in. Code that reads its own mappings sees what it would
    // on a phone.
    const Elf64_Phdr *relro = mead_image_segment(image, PT_GNU_RELRO);
    if (relro != NULL && relro->p_memsz > 0) {
        uint64_t from = relro->p_vaddr & ~((uint64_t)page - 1);
        uint64_t to = (relro->p_vaddr + relro->p_memsz + (uint64_t)page - 1) & ~((uint64_t)page - 1);
        if (mprotect(mead_image_address(image, from), (size_t)(to - from), PROT_READ) != 0)
            mead_fatal("cannot protect the RELRO of %s: %s", image->path, strerror(errno));
    }
    image->hardened = true;
}
