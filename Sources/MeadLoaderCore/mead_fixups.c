#define _GNU_SOURCE
#include "mead_fixups.h"
#include "mead_deps.h"
#include "mead_log.h"
#include "mead_symbols.h"
#include "mead_tlv.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

// The dynamic tags glibc's elf.h has not heard of. The packed forms are
// Android's, DT_LOOS + 2 on; the RELR ones came later than the elf.h some
// hosts carry, and Android had its own tags for them first.
#define DT_ANDROID_REL 0x6000000f
#define DT_ANDROID_RELSZ 0x60000010
#define DT_ANDROID_RELA 0x60000011
#define DT_ANDROID_RELASZ 0x60000012
#define DT_ANDROID_RELR 0x6fffe000
#define DT_ANDROID_RELRSZ 0x6fffe001
#ifndef DT_RELRSZ
#define DT_RELRSZ 0x23
#define DT_RELR 0x24
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

size_t mead_fixups_missing_total(void) {
    return missing_count;
}

const char *mead_fixups_missing_at(size_t index, size_t *wanted) {
    if (index >= missing_count)
        return NULL;
    if (wanted)
        *wanted = missing_entries[index].wanted;
    return missing_entries[index].name;
}

// What a stub hands back when MEAD_UNIMPLEMENTED keeps it alive: 0, as the
// ABI's "nothing came of it".
static long mead_stub_called(const char *name);

// The stub an unresolved import binds to. Each missing name gets one small
// thunk, made once and shared by every place that wants it — a library can
// import the same missing thing a thousand times — putting the name in x0,
// the argument mead_stub_called reads and one the caller's call will never
// use, and the callee on x16, the intra-procedure scratch register.
// mead_stub_called reports the name, then returns 0 under
// MEAD_UNIMPLEMENTED or aborts, naming it.
struct stub_entry {
    const char *name;
    void *thunk;
};
static struct stub_entry *stub_entries;
static size_t stub_count, stub_space;

// One thunk in the arena, or NULL when there is no room. Unlocked; callers
// hold the lock.
static void *make_thunk(const char *name) {
    // ldr x0, [pc, #16]; ldr x16, [pc, #20]; br x16; nop; .quad name;
    // .quad mead_stub_called. 32 bytes.
    enum { THUNK_SIZE = 32, ARENA_SIZE = 1024 * 1024 };
    static uint8_t *arena;
    static size_t used;
    if (!arena) {
        arena = mmap(NULL, ARENA_SIZE, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (arena == MAP_FAILED)
            arena = NULL;
    }
    if (!arena || used + THUNK_SIZE > ARENA_SIZE)
        return NULL;
    uint32_t *code = (uint32_t *)(arena + used);
    code[0] = 0x58000000u | (4u << 5) | 0;  // ldr x0, [pc, #16]
    code[1] = 0x58000000u | (5u << 5) | 16; // ldr x16, [pc, #20]
    code[2] = 0xd61f0200;                   // br x16
    code[3] = 0xd503201f;                   // nop
    uint64_t name_address = (uint64_t)(uintptr_t)name;
    uint64_t called = (uint64_t)(uintptr_t)mead_stub_called;
    memcpy(code + 4, &name_address, sizeof(name_address));
    memcpy(code + 6, &called, sizeof(called));
    __builtin___clear_cache((char *)code, (char *)code + THUNK_SIZE);
    used += THUNK_SIZE;
    return code;
}

static void *mead_stub_for(const char *name) {
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static void *unnamed;
    pthread_mutex_lock(&lock);
    for (size_t index = 0; index < stub_count; index++)
        if (strcmp(stub_entries[index].name, name) == 0) {
            pthread_mutex_unlock(&lock);
            return stub_entries[index].thunk;
        }
    if (stub_count == stub_space) {
        size_t space = stub_space ? stub_space * 2 : 64;
        struct stub_entry *grown = realloc(stub_entries, space * sizeof(*grown));
        if (!grown) {
            pthread_mutex_unlock(&lock);
            return NULL;
        }
        stub_entries = grown;
        stub_space = space;
    }
    if (!unnamed)
        unnamed = make_thunk("an unresolved function"); // made before any pressure
    void *thunk = make_thunk(name);
    if (!thunk) {
        // Out of room for a name of its own: the shared one, which says
        // only "an unresolved function", rather than nothing at all.
        pthread_mutex_unlock(&lock);
        return unnamed;
    }
    stub_entries[stub_count].name = name;
    stub_entries[stub_count].thunk = thunk;
    stub_count++;
    pthread_mutex_unlock(&lock);
    return thunk;
}

static long mead_stub_called(const char *name) {
    mead_trace("stub", "%s called", name);
    if (getenv("MEAD_UNIMPLEMENTED"))
        return 0;
    mead_fatal("%s is not implemented; MEAD_UNIMPLEMENTED=1 in the environment continues past it",
               name);
}

// Whether an image asked to prefer its own definitions (DT_SYMBOLIC, or
// DF_SYMBOLIC in DT_FLAGS).
static bool is_symbolic(const mead_image *image) {
    if (mead_image_dynamic(image, DT_SYMBOLIC))
        return true;
    const Elf64_Dyn *flags = mead_image_dynamic(image, DT_FLAGS);
    return flags && (flags->d_un.d_val & DF_SYMBOLIC);
}

// The definition one of an image's symbols binds to. As in the Android
// linker, a preemptible symbol binds to the first definition found from the
// root of the image's load — even when the image defines it too, which is
// how one operator new or one typeinfo wins across libraries — and only
// local, hidden, protected and DT_SYMBOLIC definitions stay home.
static const Elf64_Sym *definition_of(const mead_image *image, const Elf64_Sym *symbol,
                                      const char *name, const mead_image **owner) {
    bool defined = symbol->st_shndx != SHN_UNDEF;
    if (defined && (ELF64_ST_BIND(symbol->st_info) == STB_LOCAL ||
                    ELF64_ST_VISIBILITY(symbol->st_other) != STV_DEFAULT || is_symbolic(image))) {
        *owner = image;
        return symbol;
    }
    const Elf64_Sym *found = mead_deps_find_symbol(image->root, name, owner);
    if (found)
        return found;
    if (defined) {
        *owner = image;
        return symbol;
    }
    return NULL;
}

// The address a symbol binds to: images, then providers. A weak import
// nothing answers is 0, as the ABI says; only then is that its answer.
static uint64_t resolve_for(const mead_image *image, size_t symbol_index, const char *name,
                            bool *answered) {
    const Elf64_Sym *symbol = &image->symbols[symbol_index];
    const mead_image *owner = NULL;
    const Elf64_Sym *found = definition_of(image, symbol, name, &owner);
    if (found) {
        *answered = true;
        return (uint64_t)(uintptr_t)mead_image_symbol_address(owner, found);
    }
    void *address = mead_deps_provider_symbol(name);
    if (address) {
        *answered = true;
        return (uint64_t)(uintptr_t)address;
    }
    if (ELF64_ST_BIND(symbol->st_info) == STB_WEAK) {
        *answered = true;
        return 0;
    }
    note_missing(name);
    *answered = false;
    return 0;
}

// The image whose block a TLS relocation lands in, with its symbol's offset
// in that block in *value. A relocation with no symbol is the image's own,
// its addend the whole offset.
static const mead_image *tls_definition(const mead_image *image, size_t symbol_index,
                                        const char *name, uint64_t *value) {
    *value = 0;
    if (!symbol_index)
        return image;
    const Elf64_Sym *symbol = &image->symbols[symbol_index];
    const mead_image *owner = NULL;
    const Elf64_Sym *found = definition_of(image, symbol, name, &owner);
    if (found) {
        *value = found->st_value;
        return owner;
    }
    if (ELF64_ST_BIND(symbol->st_info) == STB_WEAK)
        return image;
    mead_fatal("%s wants the thread-local %s, which nothing defines", image->path, name);
}

static void apply_one(void *context, uint64_t offset, uint32_t type, size_t symbol_index,
                      int64_t addend) {
    mead_image *image = context;
    uint64_t *target = mead_image_address(image, offset);
    const char *name = symbol_index ? image->strings + image->symbols[symbol_index].st_name : NULL;
    uint64_t value = 0;

    switch (type) {
    case R_AARCH64_ABS64:
    case R_AARCH64_GLOB_DAT:
    case R_AARCH64_JUMP_SLOT: {
        if (!symbol_index) {
            *target = (uint64_t)addend;
            break;
        }
        bool answered = false;
        uint64_t address = resolve_for(image, symbol_index, name, &answered);
        if (answered)
            *target = address + (uint64_t)addend;
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

    case R_AARCH64_IRELATIVE:
        mead_fatal("%s has an IRELATIVE relocation at 0x%lx; mead does not run ifunc resolvers",
                   image->path, (unsigned long)offset);

    case R_AARCH64_TLS_DTPMOD64:
        *target = tls_definition(image, symbol_index, name, &value)->tls_module;
        break;

    case R_AARCH64_TLS_DTPREL64: {
        const mead_image *owner = tls_definition(image, symbol_index, name, &value);
        *target = mead_tlv_dtprel(owner) + value + (uint64_t)addend;
        break;
    }

    case R_AARCH64_TLS_TPREL64: {
        const mead_image *owner = tls_definition(image, symbol_index, name, &value);
        *target = (uint64_t)mead_tlv_tprel(owner) + value + (uint64_t)addend;
        break;
    }

    case R_AARCH64_TLSDESC: {
        const mead_image *owner = tls_definition(image, symbol_index, name, &value);
        // The descriptor's halves: the resolver every descriptor here
        // shares, and the TP-relative offset it hands back.
        target[0] = (uint64_t)(uintptr_t)mead_tlsdesc_resolve;
        target[1] = (uint64_t)mead_tlv_tprel(owner) + value + (uint64_t)addend;
        break;
    }

    default:
        mead_fatal("%s has a relocation mead does not know (type %u at 0x%lx); please teach it",
                   image->path, type, (unsigned long)offset);
    }
}

// A run of RELA relocations, or of the PLT's (DT_JMPREL), which are the
// same entries.
static void each_rela(const Elf64_Rela *table, size_t bytes, mead_fixup_fn visit, void *context) {
    size_t count = bytes / sizeof(*table);
    for (size_t index = 0; index < count; index++) {
        const Elf64_Rela *entry = &table[index];
        visit(context, entry->r_offset, (uint32_t)ELF64_R_TYPE(entry->r_info),
              ELF64_R_SYM(entry->r_info), entry->r_addend);
    }
}

// RELR: relative relocations, compressed. An even entry is the address of a
// word to relocate, and the next word follows it; an odd entry is a bitmap
// whose bits 1 to 63 say which of the next 63 words want it too. Their
// addends are the words themselves.
static void each_relr(const mead_image *image, const uint64_t *entries, size_t bytes,
                      mead_fixup_fn visit, void *context) {
    uint64_t next = 0;
    size_t count = bytes / sizeof(*entries);
    for (size_t index = 0; index < count; index++) {
        uint64_t entry = entries[index];
        if (!(entry & 1)) {
            visit(context, entry, R_AARCH64_RELATIVE, 0,
                  *(int64_t *)mead_image_address(image, entry));
            next = entry + 8;
            continue;
        }
        for (unsigned bit = 1; bit < 64; bit++) {
            if (!((entry >> bit) & 1))
                continue;
            uint64_t offset = next + 8ull * (bit - 1);
            visit(context, offset, R_AARCH64_RELATIVE, 0,
                  *(int64_t *)mead_image_address(image, offset));
        }
        next += 63 * 8;
    }
}

// Android's packed relocations: the magic "APS2", then SLEB128 all the way
// — the relocation count, the first offset, and groups of relocations that
// may share an offset delta, an r_info or an addend.
enum {
    PACKED_GROUPED_BY_INFO = 1,
    PACKED_GROUPED_BY_OFFSET_DELTA = 2,
    PACKED_GROUPED_BY_ADDEND = 4,
    PACKED_GROUP_HAS_ADDEND = 8,
};

struct sleb128 {
    const char *path;
    const uint8_t *at, *end;
};

static int64_t sleb128(struct sleb128 *reader) {
    int64_t value = 0;
    unsigned shift = 0;
    while (reader->at < reader->end && shift < 64) {
        uint8_t byte = *reader->at++;
        value |= (int64_t)((uint64_t)(byte & 0x7f) << shift);
        shift += 7;
        if (!(byte & 0x80)) {
            if (shift < 64 && (byte & 0x40))
                value |= (int64_t)(~0ull << shift); // sign extend
            return value;
        }
    }
    mead_fatal("%s has malformed packed relocations", reader->path);
}

static void each_packed(const mead_image *image, const uint8_t *packed, size_t bytes,
                        mead_fixup_fn visit, void *context) {
    if (bytes < 4 || memcmp(packed, "APS2", 4) != 0)
        mead_fatal("%s has packed relocations without the APS2 magic", image->path);
    struct sleb128 reader = { image->path, packed + 4, packed + bytes };
    int64_t remaining = sleb128(&reader);
    uint64_t offset = (uint64_t)sleb128(&reader);
    uint64_t info = 0;
    int64_t addend = 0;
    while (remaining > 0) {
        int64_t size = sleb128(&reader);
        int64_t flags = sleb128(&reader);
        if (size <= 0 || size > remaining)
            mead_fatal("%s has a packed relocation group of size %ld", image->path, (long)size);
        int64_t delta = 0;
        if (flags & PACKED_GROUPED_BY_OFFSET_DELTA)
            delta = sleb128(&reader);
        if (flags & PACKED_GROUPED_BY_INFO)
            info = (uint64_t)sleb128(&reader);
        if ((flags & PACKED_GROUP_HAS_ADDEND) && (flags & PACKED_GROUPED_BY_ADDEND))
            addend += sleb128(&reader);
        else if (!(flags & PACKED_GROUP_HAS_ADDEND))
            addend = 0;
        for (int64_t index = 0; index < size; index++) {
            offset += (uint64_t)((flags & PACKED_GROUPED_BY_OFFSET_DELTA) ? delta : sleb128(&reader));
            if (!(flags & PACKED_GROUPED_BY_INFO))
                info = (uint64_t)sleb128(&reader);
            if ((flags & PACKED_GROUP_HAS_ADDEND) && !(flags & PACKED_GROUPED_BY_ADDEND))
                addend += sleb128(&reader);
            visit(context, offset, (uint32_t)ELF64_R_TYPE(info), ELF64_R_SYM(info), addend);
        }
        remaining -= size;
    }
}

// A table the dynamic section names, with its size in *bytes; NULL if the
// image has none.
static const void *dynamic_table(const mead_image *image, uint64_t tag, uint64_t size_tag,
                                 size_t *bytes) {
    const Elf64_Dyn *entry = mead_image_dynamic(image, tag);
    const Elf64_Dyn *size = mead_image_dynamic(image, size_tag);
    if (!entry || !size)
        return NULL;
    *bytes = (size_t)size->d_un.d_val;
    return mead_image_address(image, (uint64_t)entry->d_un.d_ptr);
}

void mead_fixups_each(const mead_image *image, mead_fixup_fn visit, void *context) {
    if (mead_image_dynamic(image, DT_REL) || mead_image_dynamic(image, DT_ANDROID_REL))
        mead_fatal("%s has REL relocations, which arm64 does not make", image->path);
    const void *table;
    size_t bytes = 0;
    if ((table = dynamic_table(image, DT_ANDROID_RELA, DT_ANDROID_RELASZ, &bytes)))
        each_packed(image, table, bytes, visit, context);
    if ((table = dynamic_table(image, DT_RELR, DT_RELRSZ, &bytes)) ||
        (table = dynamic_table(image, DT_ANDROID_RELR, DT_ANDROID_RELRSZ, &bytes)))
        each_relr(image, table, bytes, visit, context);
    if ((table = dynamic_table(image, DT_RELA, DT_RELASZ, &bytes)))
        each_rela(table, bytes, visit, context);
    if ((table = dynamic_table(image, DT_JMPREL, DT_PLTRELSZ, &bytes)))
        each_rela(table, bytes, visit, context);
}

void mead_fixups_apply(mead_image *image) {
    mead_fixups_each(image, apply_one, image);
    mead_trace("bind", "bound %s", image->path);
}
