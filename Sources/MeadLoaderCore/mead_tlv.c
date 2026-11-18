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

// The images given blocks, in the order they got them, and how many: a
// count that only grows, published after the images it counts. Every
// thread's storage starts zeroed, so each copies the images' initial
// values (.tdata) into its own: the loading thread when they're laid out,
// and every other one on its next use of thread-local storage — ART's own
// threads, Java's, start without the bionic shim's pthread_create, and a
// library may be loaded after a thread began.
#define MEAD_TLV_MAX_IMAGES 4096
static const mead_image *laid_out[MEAD_TLV_MAX_IMAGES];
__attribute__((visibility("hidden"))) uint32_t mead_tlv_image_count;

// How many of them the calling thread has the initial values of, and where
// that count is from the thread pointer, for the resolver.
static __thread uint32_t mead_tlv_thread_images;
__attribute__((visibility("hidden"))) int64_t mead_tlv_thread_images_tprel;

// This thread's block for an image that has one.
static void *block_of(const mead_image *image) {
    return (void *)((uintptr_t)__builtin_thread_pointer() + (uint64_t)image->tls_tprel);
}

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
    if (!mead_tlv_region_tprel) {
        mead_tlv_region_tprel =
            (int64_t)(uintptr_t)mead_tlv_block_storage -
            (int64_t)(uintptr_t)__builtin_thread_pointer();
        mead_tlv_thread_images_tprel =
            (int64_t)(uintptr_t)&mead_tlv_thread_images -
            (int64_t)(uintptr_t)__builtin_thread_pointer();
    }
    uint32_t given = mead_tlv_image_count;
    size_t count = 0;
    mead_image *const *images = mead_deps_images(&count);
    for (size_t index = 0; index < count; index++) {
        mead_image *image = images[index];
        if (image->tls_memsz == 0 || image->tls_module != 0)
            continue; // no TLS, or a block already given
        used = (used + image->tls_alignment - 1) & ~(image->tls_alignment - 1);
        if (image->tls_alignment > 64)
            mead_fatal("%s wants thread-local storage aligned to %lu; mead's is aligned to 64",
                       image->path, (unsigned long)image->tls_alignment);
        uint64_t offset = used;
        used += image->tls_memsz;
        if (used > MEAD_TLV_BLOCK_SIZE)
            mead_fatal("Android libraries want %lu bytes of thread-local storage; mead has %d",
                       (unsigned long)used, MEAD_TLV_BLOCK_SIZE);
        if (given == MEAD_TLV_MAX_IMAGES)
            mead_fatal("more than %d Android libraries have thread-local storage", MEAD_TLV_MAX_IMAGES);
        image->tls_tprel = mead_tlv_region_tprel + (int64_t)offset;
        image->tls_module = 1; // every mead image shares the one module
        laid_out[given++] = image;
    }
    __atomic_store_n(&mead_tlv_image_count, given, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&lock);
    // The initial values, for the thread loading.
    mead_tlv_thread_init();
    return true;
}

size_t mead_tlv_block_bytes(void) {
    return MEAD_TLV_BLOCK_SIZE;
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
    mead_tlv_thread_init();
    return block_of(image);
}

void mead_tlv_thread_init(void) {
    uint32_t count = __atomic_load_n(&mead_tlv_image_count, __ATOMIC_ACQUIRE);
    for (uint32_t index = mead_tlv_thread_images; index < count; index++) {
        const mead_image *image = laid_out[index];
        // The rest of its block (.tbss) is still zero: the thread hasn't
        // used it, having had no offsets into it until now.
        memcpy(block_of(image),
               mead_image_address(image, mead_image_segment(image, PT_TLS)->p_vaddr),
               image->tls_filesz);
    }
    mead_tlv_thread_images = count;
}

// Handed the descriptor in x0, gives back the value half in x0, once the
// calling thread has every image's initial values (mead_tlv_thread_init).
// Written out because the TLSDESC ABI has the caller keep every other
// register live across the call, flags included, which a compiled function
// — at -O0 especially — is free not to do: the catching up saves what a C
// call may change.
__asm__(".text\n"
        ".globl mead_tlsdesc_resolve\n"
        ".type mead_tlsdesc_resolve, %function\n"
        "mead_tlsdesc_resolve:\n"
        "    stp x1, x2, [sp, #-32]!\n"
        "    str x3, [sp, #16]\n"
        "    mrs x3, nzcv\n"
        "    str x3, [sp, #24]\n"
        "    mrs x1, tpidr_el0\n"
        "    adrp x2, mead_tlv_thread_images_tprel\n"
        "    ldr x2, [x2, :lo12:mead_tlv_thread_images_tprel]\n"
        "    ldr w1, [x1, x2]\n"
        "    adrp x2, mead_tlv_image_count\n"
        "    ldr w2, [x2, :lo12:mead_tlv_image_count]\n"
        "    cmp w1, w2\n"
        "    b.ne 2f\n"
        "1:  ldr x3, [sp, #24]\n"
        "    msr nzcv, x3\n"
        "    ldr x3, [sp, #16]\n"
        "    ldp x1, x2, [sp], #32\n"
        "    ldr x0, [x0, #8]\n"
        "    ret\n"
        "2:  sub sp, sp, #656\n"
        "    stp x0, x4, [sp, #0]\n"
        "    stp x5, x6, [sp, #16]\n"
        "    stp x7, x8, [sp, #32]\n"
        "    stp x9, x10, [sp, #48]\n"
        "    stp x11, x12, [sp, #64]\n"
        "    stp x13, x14, [sp, #80]\n"
        "    stp x15, x16, [sp, #96]\n"
        "    stp x17, x18, [sp, #112]\n"
        "    stp x29, x30, [sp, #128]\n"
        "    stp q0, q1, [sp, #144]\n"
        "    stp q2, q3, [sp, #176]\n"
        "    stp q4, q5, [sp, #208]\n"
        "    stp q6, q7, [sp, #240]\n"
        "    stp q8, q9, [sp, #272]\n"
        "    stp q10, q11, [sp, #304]\n"
        "    stp q12, q13, [sp, #336]\n"
        "    stp q14, q15, [sp, #368]\n"
        "    stp q16, q17, [sp, #400]\n"
        "    stp q18, q19, [sp, #432]\n"
        "    stp q20, q21, [sp, #464]\n"
        "    stp q22, q23, [sp, #496]\n"
        "    stp q24, q25, [sp, #528]\n"
        "    stp q26, q27, [sp, #560]\n"
        "    stp q28, q29, [sp, #592]\n"
        "    stp q30, q31, [sp, #624]\n"
        "    add x29, sp, #128\n"
        "    bl mead_tlv_thread_init\n"
        "    ldp q30, q31, [sp, #624]\n"
        "    ldp q28, q29, [sp, #592]\n"
        "    ldp q26, q27, [sp, #560]\n"
        "    ldp q24, q25, [sp, #528]\n"
        "    ldp q22, q23, [sp, #496]\n"
        "    ldp q20, q21, [sp, #464]\n"
        "    ldp q18, q19, [sp, #432]\n"
        "    ldp q16, q17, [sp, #400]\n"
        "    ldp q14, q15, [sp, #368]\n"
        "    ldp q12, q13, [sp, #336]\n"
        "    ldp q10, q11, [sp, #304]\n"
        "    ldp q8, q9, [sp, #272]\n"
        "    ldp q6, q7, [sp, #240]\n"
        "    ldp q4, q5, [sp, #208]\n"
        "    ldp q2, q3, [sp, #176]\n"
        "    ldp q0, q1, [sp, #144]\n"
        "    ldp x29, x30, [sp, #128]\n"
        "    ldp x17, x18, [sp, #112]\n"
        "    ldp x15, x16, [sp, #96]\n"
        "    ldp x13, x14, [sp, #80]\n"
        "    ldp x11, x12, [sp, #64]\n"
        "    ldp x9, x10, [sp, #48]\n"
        "    ldp x7, x8, [sp, #32]\n"
        "    ldp x5, x6, [sp, #16]\n"
        "    ldp x0, x4, [sp, #0]\n"
        "    add sp, sp, #656\n"
        "    b 1b\n"
        ".size mead_tlsdesc_resolve, . - mead_tlsdesc_resolve\n");
