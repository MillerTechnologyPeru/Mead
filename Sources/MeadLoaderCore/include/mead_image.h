#ifndef MEAD_IMAGE_H
#define MEAD_IMAGE_H

// A mapped Android arm64 ELF image: its program headers, its load bias, and
// what the rest of the loader needs to find in it. Android libraries are
// ET_DYN; their segments are congruent to their file offsets modulo
// p_align, which 16 KB-page NDK builds keep at 16384 even on a 4 KB host.

#include <elf.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// glibc's elf.h has these without the 64, or not at all.
#ifndef R_AARCH64_TLS_DTPMOD64
#define R_AARCH64_TLS_DTPMOD64 1028
#define R_AARCH64_TLS_DTPREL64 1029
#define R_AARCH64_TLS_TPREL64 1030
#endif
#ifndef R_AARCH64_TLSDESC
#define R_AARCH64_TLSDESC 1031
#endif
#ifndef R_AARCH64_IRELATIVE
#define R_AARCH64_IRELATIVE 1032
#endif

typedef struct mead_image {
    char *path;                 // as loaded; owned
    char *soname;               // DT_SONAME, without the directory; owned
    int fd;
    bool mapped;                // segments are in memory
    bool hardened;              // mead_image_protect has run

    const Elf64_Phdr *phdr;     // a copy, owned
    uint16_t phnum, phentsize;
    uint64_t load_bias;         // added to the image's vaddrs
    uint64_t alignment;         // the strictest LOAD segment's p_align
    const Elf64_Dyn *dynamic;   // in the mapped image; NULL when there is none

    // mead_deps fills these:
    struct mead_image **needed; // the DT_NEEDED images, in order; owned
    size_t needed_count;
    size_t order;               // among every loaded image, in load order
    struct mead_image *root;    // the library whose load brought this one in
    bool initialized;           // its initializers have run, or are running

    // mead_symbols_setup fills these:
    const Elf64_Sym *symbols;   // DT_SYMTAB; index 0 is the null symbol
    size_t symbol_count;        // including the null symbol
    const char *strings;        // DT_STRTAB
    const uint32_t *gnu_hash;   // DT_GNU_HASH
    const uint32_t *hash;       // DT_HASH

    // mead_tlv fills these for an image with a PT_TLS segment:
    uint64_t tls_filesz, tls_memsz, tls_alignment;
    int64_t tls_tprel;          // its block's offset from the thread pointer
    uint64_t tls_module;        // its DTPMOD module id, 1 on

    void *user;                 // the providers' (the JNI runtime's) own state
} mead_image;

// Reads and validates `path`, maps its segments writable (relocations come
// next) and fills the image out. Returns NULL with *error (malloc'd, free
// it) saying why.
mead_image *mead_image_open(const char *path, char **error);

// Releases an image nothing took a liking to. Images the registry adopted
// are never released; the loader's images live as long as the process.
void mead_image_destroy(mead_image *image);

// The address a vaddr maps to: load_bias + vaddr.
static inline void *mead_image_address(const mead_image *image, uint64_t vaddr) {
    return (void *)(image->load_bias + vaddr);
}

// The first segment of a type, or NULL.
const Elf64_Phdr *mead_image_segment(const mead_image *image, uint32_t type);

// The first dynamic entry with a tag, or NULL. DT_NULL ends the table.
const Elf64_Dyn *mead_image_dynamic(const mead_image *image, uint64_t tag);

// The value a defined symbol in `image` names: its address, this thread's
// address for a thread-local one, or the symbol's st_value for the odd
// absolute one. NULL for SHN_UNDEF.
void *mead_image_symbol_address(const mead_image *image, const Elf64_Sym *symbol);

// Takes the write permission off every segment the program headers say is
// not writable, and puts execute where they say it belongs, after
// relocations have been applied; then makes the RELRO region read-only, as
// Android's linker does.
void mead_image_protect(mead_image *image);

#endif
