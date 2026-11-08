#ifndef MEAD_TLV_H
#define MEAD_TLV_H

// Every loaded image's TLS. Android libraries reach their thread_local
// variables through TP-relative offsets, TLS descriptors and
// __tls_get_addr, all of which name a block at a constant distance from the
// thread pointer; here that block is a thread-local array of the loader's
// own, so every thread that runs Android code — the main thread, and those
// the bionic shim's pthread_create makes — gets one for nothing.

#include "mead_image.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Reads `image`'s PT_TLS segment, if it has one. Call after mapping.
void mead_tlv_add(mead_image *image);

// Gives every image with a PT_TLS segment its offset in the block, copying
// the initial image into this thread's block as it goes. Images added later
// (dlopen) get theirs after. False, loudly, when the block cannot fit one.
bool mead_tlv_layout(void);

// The TP-relative offset of `image`'s block: what TPREL relocations and
// TLS descriptors carry.
int64_t mead_tlv_tprel(const mead_image *image);

// The offset in the block __tls_get_addr is given with module 1: all of
// mead's images share the one module.
uint64_t mead_tlv_dtprel(const mead_image *image);

// This thread's block for `image`, allocating nothing (the block comes with
// the thread). NULL when `image` has no PT_TLS segment.
void *mead_tlv_block(const mead_image *image);

// Copies every image's initial image into the calling thread's block. The
// loader does it for the main thread; the bionic shim's pthread_create does
// it for the threads it makes.
void mead_tlv_thread_init(void);

// How big the block is: what every thread's stack must have room for.
size_t mead_tlv_block_bytes(void);

// The TLS descriptor resolver fixups point descriptors at: handed the
// descriptor, it gives back the TP-relative offset in its value half.
// x0 in, x0 out, and every other register preserved, as the TLSDESC ABI
// asks; assembly for that reason.
int64_t mead_tlsdesc_resolve(const void *descriptor);

#endif
