#ifndef BIONIC_INTERNAL_H
#define BIONIC_INTERNAL_H

// What the shims share. Every layout here is bionic's arm64 one, as measured
// by Scripts/compare-bionic-abi.sh; the shims are named bionic_<import> and
// reach Android code only through the table in bionic_table.c.

#define _GNU_SOURCE
#include "mead_bionic.h"

#include <stdio.h>

extern const mead_startup_info *bionic_loader;

// glibc's FILE for one Android hands in: Android's __sF array is three
// placeholders standing for stdin, stdout and stderr.
FILE *bionic_file(FILE *file);

#endif
