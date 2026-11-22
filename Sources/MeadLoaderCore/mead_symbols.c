#define _GNU_SOURCE
#include "mead_symbols.h"
#include "mead_log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// DT_GNU_HASH's header: how many buckets, the symbol index the chain array
// starts at, and the bloom filter's words and shift; then the bloom words,
// the buckets and the chain.
struct gnu_hash_header {
    uint32_t buckets;
    uint32_t first_chain;
    uint32_t bloom_words;
    uint32_t bloom_shift;
};

static uint32_t gnu_hash_of(const char *name) {
    uint32_t hash = 5381;
    for (const unsigned char *at = (const unsigned char *)name; *at; at++)
        hash = hash * 33 + *at;
    return hash;
}

static uint32_t sysv_hash_of(const char *name) {
    uint32_t hash = 0;
    for (const unsigned char *at = (const unsigned char *)name; *at; at++) {
        hash = (hash << 4) + *at;
        uint32_t high = hash & 0xf0000000;
        if (high)
            hash ^= high >> 24;
        hash &= ~high;
    }
    return hash;
}

// Says why an image's symbols cannot be used; false, for returning.
static bool refuse(const mead_image *image, char **error, const char *what) {
    if (error)
        if (asprintf(error, "%s %s", image->path, what) < 0)
            *error = NULL;
    return false;
}

// DT_GNU_HASH, checked: its header, bloom filter and buckets are in the
// image, neither count is zero (lookups divide by them), and the chain has
// as many words as its segment has left. The highest symbol it names, plus
// one, in *count: the chain of the highest bucket ends where a word has its
// low bit set, which has to come before the segment does.
static bool gnu_hash_setup(mead_image *image, uint64_t vaddr, size_t *count, char **error) {
    const struct gnu_hash_header *header = vaddr % 8 == 0 ? mead_image_range(image, vaddr, sizeof(*header)) : NULL;
    if (!header)
        return refuse(image, error, "has a GNU hash table outside its segments or misaligned");
    if (header->buckets == 0 || header->bloom_words == 0)
        return refuse(image, error, "has an empty GNU hash table");
    uint64_t buckets_at = vaddr + sizeof(*header) + (uint64_t)header->bloom_words * sizeof(uint64_t);
    uint64_t chain_at = buckets_at + (uint64_t)header->buckets * sizeof(uint32_t);
    if (!mead_image_range(image, vaddr, chain_at - vaddr))
        return refuse(image, error, "has a GNU hash table past its segment");
    image->gnu_hash = (const uint32_t *)header;
    image->gnu_chain_count = (size_t)(mead_image_room(image, chain_at) / sizeof(uint32_t));
    const uint32_t *buckets = mead_image_address(image, buckets_at);
    const uint32_t *chain = mead_image_address(image, chain_at);
    uint32_t highest = 0;
    for (uint32_t index = 0; index < header->buckets; index++)
        if (buckets[index] > highest)
            highest = buckets[index];
    if (highest == 0) {
        *count = header->first_chain; // it exports nothing: no chain to walk
        return true;
    }
    if (highest < header->first_chain)
        return refuse(image, error, "has a GNU hash bucket before its chain");
    size_t word = highest - header->first_chain;
    while (word < image->gnu_chain_count && !(chain[word] & 1))
        word++;
    if (word >= image->gnu_chain_count)
        return refuse(image, error, "has a GNU hash chain with no end");
    *count = (size_t)header->first_chain + word + 1;
    return true;
}

// DT_HASH, checked: nbucket and nchain, then that many buckets and chains,
// all in the image. nchain is the symbol count.
static bool sysv_hash_setup(mead_image *image, uint64_t vaddr, size_t *count, char **error) {
    const uint32_t *hash = vaddr % 4 == 0 ? mead_image_range(image, vaddr, 2 * sizeof(uint32_t)) : NULL;
    if (!hash)
        return refuse(image, error, "has a hash table outside its segments or misaligned");
    if (hash[0] == 0 ||
        !mead_image_range(image, vaddr, (2 + (uint64_t)hash[0] + hash[1]) * sizeof(uint32_t)))
        return refuse(image, error, "has a hash table past its segment");
    image->hash = hash;
    *count = hash[1];
    return true;
}

bool mead_symbols_setup(mead_image *image, char **error) {
    const Elf64_Dyn *symtab = mead_image_dynamic(image, DT_SYMTAB);
    const Elf64_Dyn *strtab = mead_image_dynamic(image, DT_STRTAB);
    const Elf64_Dyn *strsz = mead_image_dynamic(image, DT_STRSZ);
    if (!symtab || !strtab || !strsz)
        return refuse(image, error, "has no dynamic symbols");

    // The strings: in the image, and ending in a NUL, so that a name read
    // from any offset inside them ends inside them.
    const char *strings = strsz->d_un.d_val > 0
        ? mead_image_range(image, (uint64_t)strtab->d_un.d_ptr, strsz->d_un.d_val) : NULL;
    if (!strings || strings[strsz->d_un.d_val - 1] != 0)
        return refuse(image, error, "has a string table outside its segments or without an end");
    image->strings = strings;
    image->strings_size = (size_t)strsz->d_un.d_val;

    // The symbols: as many as fit in the segment they start in, at most.
    uint64_t symbols_at = (uint64_t)symtab->d_un.d_ptr;
    size_t room = (size_t)(mead_image_room(image, symbols_at) / sizeof(Elf64_Sym));
    if (room < 1 || symbols_at % 8 != 0)
        return refuse(image, error, "has a symbol table outside its segments or misaligned");
    image->symbols = mead_image_address(image, symbols_at);

    // How many there are. The strtab usually follows the symtab in memory,
    // which says it exactly; the hash tables say it for the layouts that
    // put something between them. The smaller claim wins, so a count never
    // walks off the table.
    size_t by_address = 0, by_hash = 0;
    if (image->strings > (const char *)image->symbols)
        by_address = (size_t)((const char *)image->strings - (const char *)image->symbols) / sizeof(Elf64_Sym);
    const Elf64_Dyn *entry;
    if ((entry = mead_image_dynamic(image, DT_GNU_HASH))) {
        if (!gnu_hash_setup(image, (uint64_t)entry->d_un.d_ptr, &by_hash, error))
            return false;
    } else if ((entry = mead_image_dynamic(image, DT_HASH))) {
        if (!sysv_hash_setup(image, (uint64_t)entry->d_un.d_ptr, &by_hash, error))
            return false;
    }
    size_t count = by_address == 0 ? by_hash
                 : by_hash == 0 ? by_address
                 : by_address < by_hash ? by_address : by_hash;
    if (count > room)
        count = room;
    if (count < 1)
        return refuse(image, error, "has no symbols to count");
    for (size_t index = 0; index < count; index++)
        if (image->symbols[index].st_name >= image->strings_size)
            return refuse(image, error, "has a symbol named past its string table");
    image->symbol_count = count;
    mead_trace("load", "%s: %zu symbols%s%s", image->path, count,
               image->gnu_hash ? ", gnu hash" : "", image->hash ? ", sysv hash" : "");
    return true;
}

const Elf64_Sym *mead_symbols_find(const mead_image *image, const char *name) {
    if (image->gnu_hash) {
        const struct gnu_hash_header *header = (const struct gnu_hash_header *)image->gnu_hash;
        const uint64_t *bloom = (const uint64_t *)(header + 1);
        const uint32_t *buckets = (const uint32_t *)(bloom + header->bloom_words);
        const uint32_t *chain = buckets + header->buckets;
        uint32_t hash = gnu_hash_of(name);
        uint64_t word = bloom[(hash / 64) % header->bloom_words];
        // The bloom filter says the name may be there when both of its bits
        // for the hash are set.
        if (((word >> (hash % 64)) & (word >> ((hash >> (header->bloom_shift % 32)) % 64)) & 1) == 0)
            return NULL;
        // A chain is walked while it stays in the table: a bucket before
        // the chain's first symbol, or a chain with no end, finds nothing.
        for (uint32_t index = buckets[hash % header->buckets];
             index >= header->first_chain && index != 0 &&
             (size_t)(index - header->first_chain) < image->gnu_chain_count;) {
            uint32_t chain_hash = chain[index - header->first_chain];
            if ((chain_hash | 1) == (hash | 1) && index < image->symbol_count &&
                strcmp(image->strings + image->symbols[index].st_name, name) == 0)
                return &image->symbols[index];
            if (chain_hash & 1)
                break;
            index++;
        }
        return NULL;
    }
    if (image->hash) {
        const uint32_t *hash = image->hash; // nbucket, nchain, buckets, chains
        // At most nchain steps: a chain that loops finds nothing.
        uint32_t steps = 0;
        for (uint32_t index = hash[2 + (sysv_hash_of(name) % hash[0])];
             index != 0 && index < hash[1] && steps < hash[1];
             index = hash[2 + hash[0] + index], steps++)
            if (index < image->symbol_count &&
                strcmp(image->strings + image->symbols[index].st_name, name) == 0)
                return &image->symbols[index];
        return NULL;
    }
    for (size_t index = 1; index < image->symbol_count; index++)
        if (strcmp(image->strings + image->symbols[index].st_name, name) == 0)
            return &image->symbols[index];
    return NULL;
}

const Elf64_Sym *mead_symbols_table(const mead_image *image, size_t *count) {
    if (count)
        *count = image->symbol_count;
    return image->symbols;
}
