#define _GNU_SOURCE
#include "mead_log.h"

#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// MEAD_TRACE's comma-separated categories, cached on first use: a NULL list
// means not looked up yet, an empty first entry means tracing is off.
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static char categories[256];
static bool looked_up;

static const char *trace_categories(void) {
    pthread_mutex_lock(&lock);
    if (!looked_up) {
        const char *list = getenv("MEAD_TRACE");
        snprintf(categories, sizeof(categories), "%s", list ? list : "");
        for (char *space = categories; *space; space++)
            if (*space == ' ')
                *space = 0;
        looked_up = true;
    }
    pthread_mutex_unlock(&lock);
    return categories;
}

bool mead_trace_wants(const char *category) {
    static char all[] = "all";
    if (strcmp(category, all) == 0)
        return true;
    const char *list = trace_categories();
    if (!*list)
        return false;
    size_t length = strlen(category);
    for (const char *item = list;; item += strlen(item) + 1) {
        if (strncmp(item, category, length) == 0 &&
            (item[length] == 0 || item[length] == ','))
            return true;
        const char *comma = strchr(item, ',');
        if (!comma)
            return false;
        item = comma; // the loop's increment steps past the comma
    }
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
