#ifndef MEAD_FIXUPS_H
#define MEAD_FIXUPS_H

// Applies an image's relocations: RELA, RELR, Android's packed forms and
// the TLS ones, against the dependency registry. What no image or provider
// answers binds to a stub that names the missing symbol when called —
// MEAD_UNIMPLEMENTED=1 has the stub return 0 instead of aborting — and
// MEAD_STRICT=1 fails the load outright.

#include "mead_image.h"

void mead_fixups_apply(mead_image *image);

// One relocation, however the image stored it. RELR entries come through as
// R_AARCH64_RELATIVE with the word they relocate as the addend.
typedef void (*mead_fixup_fn)(void *context, uint64_t offset, uint32_t type,
                              size_t symbol_index, int64_t addend);

// Every relocation an image carries, in every table it keeps them in.
void mead_fixups_each(const mead_image *image, mead_fixup_fn visit, void *context);

// The imports nothing answered, across every image applied, for --report:
// how many, and each name with how many places wanted it. NULL past the end.
size_t mead_fixups_missing_total(void);
const char *mead_fixups_missing_at(size_t index, size_t *wanted);

#endif
