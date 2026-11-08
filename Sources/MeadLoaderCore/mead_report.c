#define _GNU_SOURCE
#include "mead_deps.h"
#include "mead_fixups.h"
#include "mead_image.h"
#include "mead_loader.h"
#include "mead_symbols.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// mead --report: load and bind without running anything, then say what a
// library is made of — its images, what each needs, the relocations in it,
// the JNI class names among its strings, and the imports nothing answered.

static const char *relocation_name(uint32_t type) {
    switch (type) {
    case R_AARCH64_ABS64: return "ABS64";
    case R_AARCH64_GLOB_DAT: return "GLOB_DAT";
    case R_AARCH64_JUMP_SLOT: return "JUMP_SLOT";
    case R_AARCH64_RELATIVE: return "RELATIVE";
    case R_AARCH64_TLS_DTPMOD64: return "TLS_DTPMOD64";
    case R_AARCH64_TLS_DTPREL64: return "TLS_DTPREL64";
    case R_AARCH64_TLS_TPREL64: return "TLS_TPREL64";
    case R_AARCH64_TLSDESC: return "TLSDESC";
    case R_AARCH64_IRELATIVE: return "IRELATIVE";
    default: return NULL;
    }
}

enum { ABS, GLOB, JUMP, RELATIVE, DTPMOD, DTPREL, TPREL, TLSDESC, IREL, OTHER, KINDS };

// Counts one relocation, of whichever table it came from.
static void count_relocation(void *context, uint64_t offset, uint32_t type, size_t symbol_index,
                             int64_t addend) {
    size_t *counts = context;
    (void)offset, (void)symbol_index, (void)addend;
    switch (type) {
    case R_AARCH64_ABS64: counts[ABS]++; break;
    case R_AARCH64_GLOB_DAT: counts[GLOB]++; break;
    case R_AARCH64_JUMP_SLOT: counts[JUMP]++; break;
    case R_AARCH64_RELATIVE: counts[RELATIVE]++; break;
    case R_AARCH64_TLS_DTPMOD64: counts[DTPMOD]++; break;
    case R_AARCH64_TLS_DTPREL64: counts[DTPREL]++; break;
    case R_AARCH64_TLS_TPREL64: counts[TPREL]++; break;
    case R_AARCH64_TLSDESC: counts[TLSDESC]++; break;
    case R_AARCH64_IRELATIVE: counts[IREL]++; break;
    default: counts[OTHER]++; break;
    }
}

// Whether a run of bytes has the shape of what FindClass and GetMethodID are
// handed: a signature, (Ljava/lang/String;)V, or a class as a/b/Name, perhaps
// as the descriptor [La/b/Name;. Packages start lower case and classes upper
// case, which is what tells them from a game's file paths.
static bool class_like(const char *string, size_t length) {
    if (string[0] == '(') {
        const char *close = strchr(string, ')');
        return close && close[1] && strchr("VZBCSIJFDL[", close[1]) &&
               strspn(string, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
                              "0123456789_$/;[()") == length;
    }
    const char *start = string, *end = string + length;
    while (start < end && *start == '[')
        start++;
    if (end - start > 2 && *start == 'L' && end[-1] == ';') {
        start++;
        end--;
    }
    if (start == end || !islower((unsigned char)*start))
        return false;
    bool slash = false;
    const char *segment = start;
    for (const char *at = start; at < end; at++) {
        if (*at == '/') {
            if (at == segment)
                return false;
            slash = true;
            segment = at + 1;
        } else if (!isalnum((unsigned char)*at) && *at != '_' && *at != '$') {
            return false;
        }
    }
    return slash && segment < end && isupper((unsigned char)*segment);
}

// Prints the JNI class-name candidates in an image's read-only bytes,
// deduplicated, newest first capped: what FindClass and GetMethodID are
// handed, as strings between the code.
static void report_jni_classes(const mead_image *image) {
    printf("  jni classes (candidates):\n");
    enum { MAX = 512 };
    static char seen[MAX][192];
    size_t seen_count = 0;
    for (uint16_t segment = 0; segment < image->phnum && seen_count < MAX; segment++) {
        const Elf64_Phdr *at = (const Elf64_Phdr *)
            ((const char *)image->phdr + (size_t)segment * image->phentsize);
        if (at->p_type != PT_LOAD || (at->p_flags & PF_W))
            continue;
        const char *bytes = mead_image_address(image, at->p_vaddr);
        size_t length = (size_t)at->p_filesz;
        size_t run = 0;
        for (size_t index = 0; index <= length && seen_count < MAX; index++) {
            char character = index < length ? bytes[index] : 0;
            if (character && !iscntrl((unsigned char)character) && character != ' ') {
                run++;
                continue;
            }
            if (run >= 8 && run < sizeof(seen[0])) {
                char candidate[sizeof(seen[0])];
                memcpy(candidate, bytes + index - run, run);
                candidate[run] = 0;
                if (class_like(candidate, run)) {
                    bool duplicate = false;
                    for (size_t which = 0; which < seen_count; which++)
                        if (strcmp(seen[which], candidate) == 0)
                            duplicate = true;
                    if (!duplicate) {
                        snprintf(seen[seen_count++], sizeof(seen[0]), "%s", candidate);
                        printf("    %s\n", candidate);
                    }
                }
            }
            run = 0;
        }
    }
}

int mead_report(const char *path) {
    char *error = NULL;
    mead_image *image = mead_deps_add(path, &error);
    if (!image) {
        fprintf(stderr, "mead: cannot load: %s\n", error ? error : "out of memory");
        free(error);
        return 1;
    }
    mead_bind_loaded();
    size_t count = 0;
    mead_image *const *images = mead_deps_images(&count);

    printf("%s\n", path);
    for (size_t index = 0; index < count; index++) {
        const mead_image *at = images[index];
        printf("  image %s (%s, align %lu)\n", at->path, at->soname ? at->soname : "no soname",
               (unsigned long)at->alignment);
        size_t symbols = 0;
        const Elf64_Sym *table = mead_symbols_table(at, &symbols);
        size_t imports = 0;
        for (size_t which = 1; which < symbols; which++)
            if (table[which].st_shndx == SHN_UNDEF && table[which].st_name != 0 &&
                ELF64_ST_BIND(table[which].st_info) != STB_WEAK)
                imports++;
        printf("    %zu symbols, %zu imports, %zu needed\n", symbols, imports, at->needed_count);
        for (size_t needed = 0; needed < at->needed_count; needed++)
            printf("      needs %s\n", at->needed[needed]->soname ? at->needed[needed]->soname
                                                                  : at->needed[needed]->path);
        size_t counts[KINDS] = { 0 };
        mead_fixups_each(at, count_relocation, counts);
        static const char *names[KINDS] = { "ABS64",     "GLOB_DAT",  "JUMP_SLOT", "RELATIVE",
                                         "DTPMOD64",  "DTPREL64",  "TPREL64",   "TLSDESC",
                                         "IRELATIVE", "other" };
        printf("    relocations:");
        for (int which = 0; which < KINDS; which++)
            if (counts[which])
                printf(" %s=%zu", names[which], counts[which]);
        printf("\n");
        (void)relocation_name;
    }
    report_jni_classes(image);

    size_t missing = mead_fixups_missing_total();
    if (missing) {
        printf("  missing (%zu):\n", missing);
        for (size_t index = 0; index < missing; index++) {
            size_t wanted = 0;
            const char *name = mead_fixups_missing_at(index, &wanted);
            printf("    %s (wanted %zu times)\n", name, wanted);
        }
        return 1;
    }
    printf("  nothing missing\n");
    return 0;
}
