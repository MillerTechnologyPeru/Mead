#ifndef MEAD_FIXUPS_H
#define MEAD_FIXUPS_H

// Applies an image's relocations: RELA, RELR, Android's packed forms and
// the TLS ones, against the dependency registry. What no image or provider
// answers binds to a stub that names the missing symbol when called —
// MEAD_UNIMPLEMENTED=1 has the stub return 0 instead of aborting — and
// MEAD_STRICT=1 fails the load outright.

#include "mead_image.h"

void mead_fixups_apply(mead_image *image);

// The imports nothing answered, across every image applied, for --report:
// each name, and how many places wanted it.
const char *const *mead_fixups_missing(size_t *count);
size_t mead_fixups_missing_count(const char *name);

#endif
