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

// How many symbols the table holds. The strtab usually follows the symtab
// in memory, which says it exactly; the hash tables say it for the layouts
// that put something between them. The smaller claim wins, so a count never
// walks off the table.
static size_t symbol_count(const mead_image *image) {
    size_t by_address = 0;
    if (image->strings > (const char *)image->symbols)
        by_address = (size_t)((const char *)image->strings - (const char *)image->symbols) / sizeof(Elf64_Sym);
    size_t by_hash = 0;
    if (image->gnu_hash) {
        const struct gnu_hash_header *header = (const struct gnu_hash_header *)image->gnu_hash;
        const uint64_t *bloom = (const uint64_t *)(header + 1);
        const uint32_t *buckets = (const uint32_t *)(bloom + header->bloom_words);
        const uint32_t *chain = buckets + header->buckets;
        uint32_t highest = 0;
        for (uint32_t index = 0; index < header->buckets; index++)
            if (buckets[index] > highest)
                highest = buckets[index];
        if (highest == 0) {
            by_hash = header->first_chain; // it exports nothing: no chain to walk
        } else {
            uint32_t word = highest - header->first_chain;
            while (!(chain[word] & 1))
                word++; // the chain ends where a word has its low bit set
            by_hash = (size_t)(header->first_chain + word + 1);
        }
    } else if (image->hash) {
        by_hash = image->hash[1]; // nchain
    }
    if (by_address == 0)
        return by_hash;
    if (by_hash == 0)
        return by_address;
    return by_address < by_hash ? by_address : by_hash;
}

bool mead_symbols_setup(mead_image *image, char **error) {
    const Elf64_Dyn *entry;
    if ((entry = mead_image_dynamic(image, DT_SYMTAB)))
        image->symbols = mead_image_address(image, (uint64_t)entry->d_un.d_ptr);
    if ((entry = mead_image_dynamic(image, DT_STRTAB)))
        image->strings = mead_image_address(image, (uint64_t)entry->d_un.d_ptr);
    if ((entry = mead_image_dynamic(image, DT_GNU_HASH)))
        image->gnu_hash = mead_image_address(image, (uint64_t)entry->d_un.d_ptr);
    if ((entry = mead_image_dynamic(image, DT_HASH)))
        image->hash = mead_image_address(image, (uint64_t)entry->d_un.d_ptr);
    if (!image->symbols || !image->strings) {
        if (error)
            if (asprintf(error, "%s has no dynamic symbols", image->path) < 0)
                *error = NULL;
        return false;
    }
    size_t count = symbol_count(image);
    if (count < 1) {
        if (error)
            if (asprintf(error, "%s has no symbols to count", image->path) < 0)
                *error = NULL;
        return false;
    }
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
        if (((word >> (hash % 64)) & (word >> ((hash >> header->bloom_shift) % 64)) & 1) == 0)
            return NULL;
        for (uint32_t index = buckets[hash % header->buckets]; index != 0;) {
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
        for (uint32_t index = hash[2 + (sysv_hash_of(name) % hash[0])]; index != 0;
             index = hash[2 + hash[0] + index])
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
