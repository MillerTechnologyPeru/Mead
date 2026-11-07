#define _GNU_SOURCE
#include "mead_fixups.h"
#include "mead_deps.h"
#include "mead_log.h"
#include "mead_symbols.h"
#include "mead_tlv.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

// The dynamic tags and relocation numbers glibc's elf.h has not heard of.
// The packed forms are Android's; the RELR ones came later than the elf.h
// some hosts carry.
#ifndef DT_ANDROID_REL
#define DT_ANDROID_REL 0x60000008
#define DT_ANDROID_RELSZ 0x60000009
#define DT_ANDROID_RELA 0x6000000a
#define DT_ANDROID_RELASZ 0x6000000b
#endif
#ifndef DT_RELRSZ
#define DT_RELRSZ 0x23
#define DT_RELR 0x24
#define DT_RELRENT 0x25
#endif
#ifndef R_AARCH64_IRELATIVE
#define R_AARCH64_IRELATIVE 1032
#endif

// An entry in the missing list: what was wanted, and how many times.
struct missing {
    char *name;
    size_t wanted;
};
static pthread_mutex_t missing_lock = PTHREAD_MUTEX_INITIALIZER;
static struct missing *missing_entries;
static size_t missing_count, missing_space;

static void note_missing(const char *name) {
    pthread_mutex_lock(&missing_lock);
    for (size_t index = 0; index < missing_count; index++)
        if (strcmp(missing_entries[index].name, name) == 0) {
            missing_entries[index].wanted++;
            pthread_mutex_unlock(&missing_lock);
            return;
        }
    if (missing_count == missing_space) {
        size_t space = missing_space ? missing_space * 2 : 32;
        struct missing *grown = realloc(missing_entries, space * sizeof(*grown));
        if (!grown) {
            pthread_mutex_unlock(&missing_lock);
            return;
        }
        missing_entries = grown;
        missing_space = space;
    }
    missing_entries[missing_count].name = strdup(name);
    missing_entries[missing_count].wanted = 1;
    missing_count++;
    pthread_mutex_unlock(&missing_lock);
}

const char *const *mead_fixups_missing(size_t *count) {
    if (count)
        *count = missing_count;
    return (const char *const *)missing_entries;
}

size_t mead_fixups_missing_count(const char *name) {
    for (size_t index = 0; index < missing_count; index++)
        if (strcmp(missing_entries[index].name, name) == 0)
            return missing_entries[index].wanted;
    return 0;
}

// What a stub hands back when MEAD_UNIMPLEMENTED keeps it alive: 0, as the
// ABI's "nothing came of it".
static long mead_stub_called(const char *name);

// The stub an unresolved import binds to. Each missing name gets a small
// thunk — x16 and x17 are the intra-procedure scratch registers, free at a
// function's entry — that hands the name to mead_stub_called, which reports
// it, then returns 0 under MEAD_UNIMPLEMENTED or aborts, naming it.
static void *mead_stub_for(const char *name) {
    // ldr x17, [pc, #16]; ldr x16, [pc, #20]; br x16; nop; .quad name;
    // .quad mead_stub_called. 32 bytes.
    enum { THUNK_SIZE = 32, ARENA_SIZE = 64 * 1024 };
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static uint8_t *arena;
    static size_t used;
    pthread_mutex_lock(&lock);
    if (!arena) {
        arena = mmap(NULL, ARENA_SIZE, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (arena == MAP_FAILED) {
            arena = NULL;
            pthread_mutex_unlock(&lock);
            return NULL;
        }
    }
    if (used + THUNK_SIZE > ARENA_SIZE) {
        pthread_mutex_unlock(&lock);
        return NULL;
    }
    uint32_t *code = (uint32_t *)(arena + used);
    code[0] = 0x58000000u | (4u << 5) | 17; // ldr x17, [pc, #16]
    code[1] = 0x58000000u | (5u << 5) | 16; // ldr x16, [pc, #20]
    code[2] = 0xd61f0200;                   // br x16
    code[3] = 0xd503201f;                   // nop
    uint64_t name_address = (uint64_t)(uintptr_t)name;
    uint64_t called = (uint64_t)(uintptr_t)mead_stub_called;
    memcpy(code + 4, &name_address, sizeof(name_address));
    memcpy(code + 6, &called, sizeof(called));
    used += THUNK_SIZE;
    pthread_mutex_unlock(&lock);
    return code;
}

static long mead_stub_called(const char *name) {
    mead_trace("stub", "%s called", name);
    if (getenv("MEAD_UNIMPLEMENTED"))
        return 0;
    mead_fatal("%s is not implemented; MEAD_UNIMPLEMENTED=1 in the environment continues past it",
               name);
}

// The providers' answer for a name, noted as missing when there is none.
static uint64_t provider_answer(const char *name, bool *answered) {
    void *address = mead_deps_provider_symbol(name);
    if (address) {
        *answered = true;
        return (uint64_t)(uintptr_t)address;
    }
    note_missing(name);
    *answered = false;
    return 0;
}

// A symbol the registry way — what the image needs, then everything — with
// the providers behind it, leaving the defining image in *owner.
static uint64_t resolve_for(mead_image *image, size_t symbol_index, const char *name,
                            const mead_image **owner, bool *answered) {
    const Elf64_Sym *symbol = &image->symbols[symbol_index];
    if (symbol->st_shndx != SHN_UNDEF) {
        *owner = image;
        *answered = true;
        return (uint64_t)(uintptr_t)mead_image_symbol_address(image, symbol);
    }
    if (ELF64_ST_BIND(symbol->st_info) == STB_WEAK) {
        *owner = image;
        *answered = true; // a weak import nothing answers is 0, as the ABI says
        return 0;
    }
    const mead_image *found_in = NULL;
    const Elf64_Sym *found = mead_deps_find_symbol(image, name, &found_in);
    if (found) {
        *owner = found_in;
        *answered = true;
        return (uint64_t)(uintptr_t)mead_image_symbol_address(found_in, found);
    }
    return provider_answer(name, answered);
}

static void apply_one(mead_image *image, uint64_t offset, uint32_t type, size_t symbol_index,
                      int64_t addend) {
    uint64_t *target = mead_image_address(image, offset);
    const char *name = symbol_index ? image->strings + image->symbols[symbol_index].st_name : NULL;

    switch (type) {
    case R_AARCH64_ABS64:
    case R_AARCH64_GLOB_DAT:
    case R_AARCH64_JUMP_SLOT: {
        if (!symbol_index) {
            *target = (uint64_t)addend;
            break;
        }
        bool answered = false;
        const mead_image *owner = image;
        uint64_t value = resolve_for(image, symbol_index, name, &owner, &answered);
        if (answered)
            *target = value + (uint64_t)addend;
        else if (getenv("MEAD_STRICT"))
            mead_fatal("%s imports %s, which nothing answers (MEAD_STRICT)", image->path, name);
        else {
            void *stub = mead_stub_for(name);
            if (!stub)
                mead_fatal("cannot make a stub for %s", name);
            *target = (uint64_t)(uintptr_t)stub;
        }
        break;
    }

    case R_AARCH64_RELATIVE:
        *target = image->load_bias + (uint64_t)addend;
        break;

    case R_AARCH64_IRELATIVE: {
        void *(*resolver)(void) = (void *(*)(void))mead_image_address(image, (uint64_t)addend);
        *target = (uint64_t)(uintptr_t)resolver();
        mead_trace("bind", "ifunc resolved to %p", (void *)*target);
        break;
    }

    case R_AARCH64_TLS_DTPMOD64: {
        const mead_image *owner = image;
        bool answered = false;
        if (symbol_index)
            (void)resolve_for(image, symbol_index, name, &owner, &answered);
        *target = owner->tls_module;
        break;
    }

    case R_AARCH64_TLS_DTPREL64: {
        const mead_image *owner = image;
        bool answered = false;
        if (symbol_index)
            (void)resolve_for(image, symbol_index, name, &owner, &answered);
        *target = mead_tlv_dtprel(owner) + (uint64_t)addend;
        break;
    }

    case R_AARCH64_TLS_TPREL64: {
        const mead_image *owner = image;
        bool answered = false;
        if (symbol_index)
            (void)resolve_for(image, symbol_index, name, &owner, &answered);
        *target = (uint64_t)mead_tlv_tprel(owner) + (uint64_t)addend;
        break;
    }

    case R_AARCH64_TLSDESC: {
        const mead_image *owner = image;
        bool answered = false;
        if (symbol_index)
            (void)resolve_for(image, symbol_index, name, &owner, &answered);
        // The descriptor's halves: the resolver every descriptor here
        // shares, and the TP-relative offset it hands back.
        target[0] = (uint64_t)(uintptr_t)mead_tlsdesc_resolve;
        target[1] = (uint64_t)mead_tlv_tprel(owner) + (uint64_t)addend;
        break;
    }

    default:
        mead_fatal("%s has a relocation mead does not know (type %u at 0x%lx); please teach it",
                   image->path, type, (unsigned long)offset);
    }
}

// A run of RELA relocations, or of the PLT's (DT_JMPREL), which are the
// same entries.
static void apply_rela(mead_image *image, const Elf64_Rela *table, size_t bytes) {
    size_t count = bytes / sizeof(*table);
    for (size_t index = 0; index < count; index++) {
        const Elf64_Rela *entry = &table[index];
        apply_one(image, entry->r_offset, (uint32_t)ELF64_R_TYPE(entry->r_info),
                  ELF64_R_SYM(entry->r_info), entry->r_addend);
    }
}

// RELR: relative relocations two bits at a time. An entry with its top bit
// set names the next address (and relocates it); the rest are bitmaps
// saying which of the following words want bias added.
static void apply_relr(mead_image *image, const uint64_t *entries, size_t bytes) {
    uint64_t where = 0;
    size_t count = bytes / sizeof(*entries);
    for (size_t index = 0; index < count; index++) {
        uint64_t entry = entries[index];
        if (entry & (1ull << 63)) {
            where = image->load_bias + (entry & ~(1ull << 63));
            *(uint64_t *)(uintptr_t)where += image->load_bias;
        } else {
            for (int bit = 0; bit < 63; bit++)
                if (entry & (1ull << bit))
                    *(uint64_t *)(uintptr_t)(where + 8ull * (bit + 1)) += image->load_bias;
            where += 63 * 8;
        }
    }
}

// Android's packed relocations, SLEB128 all the way: a signed count (a
// negative count means the REL form, without addends), then, for each,
// the offset as a delta from the last, the r_info, and the addend.
struct sleb128 {
    const uint8_t *at, *end;
};

static int64_t sleb128(struct sleb128 *reader, bool *ok) {
    int64_t value = 0;
    unsigned shift = 0;
    while (reader->at < reader->end) {
        uint8_t byte = *reader->at++;
        value |= (int64_t)(byte & 0x7f) << shift;
        shift += 7;
        if (!(byte & 0x80)) {
            if (shift < 64 && (byte & 0x40))
                value |= -1ll << shift; // sign extend
            return value;
        }
        if (shift > 63) {
            *ok = false;
            return 0;
        }
    }
    *ok = false;
    return 0;
}

static void apply_packed(mead_image *image, const uint8_t *packed, size_t bytes) {
    struct sleb128 reader = { packed, packed + bytes };
    bool ok = true;
    int64_t count = sleb128(&reader, &ok);
    if (!ok || count == 0)
        return;
    bool with_addends = count > 0;
    if (count < 0)
        count = -count;
    uint64_t offset = 0;
    for (int64_t index = 0; index < count; index++) {
        int64_t delta = sleb128(&reader, &ok);
        int64_t info = sleb128(&reader, &ok);
        if (!ok)
            return;
        offset += (uint64_t)delta;
        int64_t addend;
        if (with_addends)
            addend = sleb128(&reader, &ok);
        else
            addend = (int64_t)*(uint64_t *)mead_image_address(image, offset);
        if (!ok)
            return;
        apply_one(image, offset, (uint32_t)((uint64_t)info & 0xffffffff),
                  (size_t)((uint64_t)info >> 32), addend);
    }
}

void mead_fixups_apply(mead_image *image) {
    const Elf64_Dyn *entry;
    if (mead_image_dynamic(image, DT_REL))
        mead_fatal("%s has REL relocations, which arm64 does not make", image->path);
    if ((entry = mead_image_dynamic(image, DT_RELA))) {
        size_t size = 0;
        const Elf64_Dyn *size_entry = mead_image_dynamic(image, DT_RELASZ);
        if (size_entry)
            size = (size_t)size_entry->d_un.d_val;
        apply_rela(image, mead_image_address(image, (uint64_t)entry->d_un.d_ptr), size);
    }
    if ((entry = mead_image_dynamic(image, DT_JMPREL))) {
        size_t size = 0;
        const Elf64_Dyn *size_entry = mead_image_dynamic(image, DT_PLTRELSZ);
        if (size_entry)
            size = (size_t)size_entry->d_un.d_val;
        apply_rela(image, mead_image_address(image, (uint64_t)entry->d_un.d_ptr), size);
    }
    if ((entry = mead_image_dynamic(image, DT_RELR))) {
        size_t size = 0;
        const Elf64_Dyn *size_entry = mead_image_dynamic(image, DT_RELRSZ);
        if (size_entry)
            size = (size_t)size_entry->d_un.d_val;
        apply_relr(image, mead_image_address(image, (uint64_t)entry->d_un.d_ptr), size);
    }
    if ((entry = mead_image_dynamic(image, DT_ANDROID_RELA))) {
        size_t size = 0;
        const Elf64_Dyn *size_entry = mead_image_dynamic(image, DT_ANDROID_RELASZ);
        if (size_entry)
            size = (size_t)size_entry->d_un.d_val;
        apply_packed(image, mead_image_address(image, (uint64_t)entry->d_un.d_ptr), size);
    }
    if ((entry = mead_image_dynamic(image, DT_ANDROID_REL))) {
        size_t size = 0;
        const Elf64_Dyn *size_entry = mead_image_dynamic(image, DT_ANDROID_RELSZ);
        if (size_entry)
            size = (size_t)size_entry->d_un.d_val;
        apply_packed(image, mead_image_address(image, (uint64_t)entry->d_un.d_ptr), size);
    }
    mead_trace("bind", "bound %s", image->path);
}
