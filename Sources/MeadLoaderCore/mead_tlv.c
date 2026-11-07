#define _GNU_SOURCE
#include "mead_tlv.h"
#include "mead_deps.h"
#include "mead_log.h"

#include <pthread.h>
#include <stdio.h>
#include <string.h>

// The block every thread runs Android code with. Its distance from the
// thread pointer is the same in every thread, it being initial-exec TLS of
// the loader itself, which is what makes TPREL relocations and TLS
// descriptors constant: a block's address is always TP + tprel. Android
// libraries' thread_local use — a game's renderers, an engine's allocators
// — runs to tens of kilobytes; half a megabyte leaves room to spare, paid
// per thread that runs Android code.
#define MEAD_TLV_BLOCK_SIZE (512 * 1024)

static __thread uint8_t mead_tlv_block_storage[MEAD_TLV_BLOCK_SIZE]
    __attribute__((aligned(64)));

// The storage's own TP-relative offset, the same in every thread. Where the
// next image's block goes, moving only forward: relocations bake offsets
// in, so a block never moves once given.
static int64_t mead_tlv_region_tprel;
static uint64_t used;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

void mead_tlv_add(mead_image *image) {
    const Elf64_Phdr *tls = mead_image_segment(image, PT_TLS);
    if (!tls)
        return;
    image->tls_filesz = tls->p_filesz;
    image->tls_memsz = tls->p_memsz;
    image->tls_alignment = tls->p_align ? tls->p_align : 1;
}

bool mead_tlv_layout(void) {
    pthread_mutex_lock(&lock);
    if (!mead_tlv_region_tprel)
        mead_tlv_region_tprel =
            (int64_t)(uintptr_t)mead_tlv_block_storage -
            (int64_t)(uintptr_t)__builtin_thread_pointer();
    size_t count = 0;
    mead_image *const *images = mead_deps_images(&count);
    for (size_t index = 0; index < count; index++) {
        mead_image *image = images[index];
        if (image->tls_memsz == 0 || image->tls_module != 0)
            continue; // no TLS, or a block already given
        used = (used + image->tls_alignment - 1) & ~(image->tls_alignment - 1);
        uint64_t offset = used;
        used += image->tls_memsz;
        if (used > MEAD_TLV_BLOCK_SIZE)
            mead_fatal("Android libraries want %lu bytes of thread-local storage; mead has %d",
                       (unsigned long)used, MEAD_TLV_BLOCK_SIZE);
        image->tls_tprel = mead_tlv_region_tprel + (int64_t)offset;
        image->tls_module = 1; // every mead image shares the one module
        // The initial image, for the thread loading: the ones made later
        // copy it in mead_tlv_thread_init.
        memcpy(mead_tlv_block(image),
               mead_image_address(image, mead_image_segment(image, PT_TLS)->p_vaddr),
               image->tls_filesz);
    }
    pthread_mutex_unlock(&lock);
    return true;
}

int64_t mead_tlv_tprel(const mead_image *image) {
    return image->tls_tprel;
}

uint64_t mead_tlv_dtprel(const mead_image *image) {
    return (uint64_t)(image->tls_tprel - mead_tlv_region_tprel);
}

void *mead_tlv_block(const mead_image *image) {
    if (image->tls_memsz == 0 || image->tls_module == 0)
        return NULL;
    return (void *)((uintptr_t)__builtin_thread_pointer() + (uint64_t)image->tls_tprel);
}

void mead_tlv_thread_init(void) {
    size_t count = 0;
    mead_image *const *images = mead_deps_images(&count);
    for (size_t index = 0; index < count; index++) {
        const mead_image *image = images[index];
        if (image->tls_memsz == 0 || image->tls_module == 0)
            continue;
        memcpy(mead_tlv_block(image),
               mead_image_address(image, mead_image_segment(image, PT_TLS)->p_vaddr),
               image->tls_filesz);
        // The storage starts zeroed in every thread; only what a later
        // dlopen added after this thread began would need clearing, and the
        // copy above has already covered its filesz.
    }
}

int64_t mead_tlsdesc_resolve(const void *descriptor) {
    // The descriptor's halves: who to call, and what to hand back.
    const struct {
        int64_t (*resolver)(const void *);
        int64_t value;
    } *tlsdesc = descriptor;
    return tlsdesc->value;
}
