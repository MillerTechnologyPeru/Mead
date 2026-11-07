#ifndef MEAD_SYMBOLS_H
#define MEAD_SYMBOLS_H

// An image's dynamic symbols: the table, its strings, and lookup by name
// through the GNU or SysV hash table the library carries, falling back to
// walking the table for the odd library with neither.

#include "mead_image.h"

#include <stdbool.h>

// Reads DT_SYMTAB, DT_STRTAB, DT_HASH and DT_GNU_HASH into `image`. True,
// or false with *error (malloc'd, free it) for a table past its strings.
bool mead_symbols_setup(mead_image *image, char **error);

// The symbol a name names in `image`, or NULL. Versioned symbols are not
// distinguished: the first of the name wins, as the Android linker's flat
// search does.
const Elf64_Sym *mead_symbols_find(const mead_image *image, const char *name);

// Every symbol in `image` that another image could import, in table order:
// index 1 on. count comes from mead_symbols_setup.
const Elf64_Sym *mead_symbols_table(const mead_image *image, size_t *count);

#endif
