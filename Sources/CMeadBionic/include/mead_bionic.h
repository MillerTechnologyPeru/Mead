#ifndef MEAD_BIONIC_H
#define MEAD_BIONIC_H

// The boundary between libMeadBionic.so's C half, which has the table of
// everything Android code may import and the shims behind it, and its Swift
// half, which has the provider's entry points, the logging and the system
// properties.

#include "mead_interface.h"

#include <stddef.h>

// The address Android code gets for an imported name, or NULL.
void *mead_bionic_lookup(const char *name);

// Keeps the loader's services for the shims that need them.
void mead_bionic_startup(const mead_startup_info *info);

// Implemented in Swift.
void mead_bionic_log_write(int priority, const char *tag, const char *text);
int mead_bionic_property_get(const char *name, char *value);
const void *mead_bionic_property_find(const char *name);
const void *mead_bionic_property_at(unsigned index);
void mead_bionic_property_copy(const void *property, char *name, char *value);

#endif
