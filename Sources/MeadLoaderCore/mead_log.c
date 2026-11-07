#define _GNU_SOURCE
#include "mead_log.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// MEAD_TRACE's comma-separated categories, read from the environment each
// time: cheap next to printing, and always in step with it.

bool mead_trace_wants(const char *category) {
    if (strcmp(category, "all") == 0)
        return true;
    const char *list = getenv("MEAD_TRACE");
    if (!list || !*list)
        return false;
    size_t length = strlen(category);
    for (const char *item = list; item;) {
        if (strncmp(item, category, length) == 0 &&
            (item[length] == 0 || item[length] == ','))
            return true;
        item = strchr(item, ',');
        if (item)
            item++;
    }
    return false;
}

void mead_fatal(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    fputs("mead: ", stderr);
    vfprintf(stderr, format, arguments);
    fputc('\n', stderr);
    va_end(arguments);
    exit(1);
}

void mead_trace(const char *category, const char *format, ...) {
    if (!mead_trace_wants(category))
        return;
    va_list arguments;
    va_start(arguments, format);
    fprintf(stderr, "mead(%s): ", category);
    vfprintf(stderr, format, arguments);
    fputc('\n', stderr);
    va_end(arguments);
}
