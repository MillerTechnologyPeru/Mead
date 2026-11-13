#include "bionic_internal.h"

#include <poll.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <unistd.h>

// The _FORTIFY_SOURCE entry points glibc doesn't share with bionic, by name
// or by argument order. An overflow caught here ends the process, as it does
// on Android.

static _Noreturn void overflow(const char *function) {
    fprintf(stderr, "mead: %s: prevented a buffer overflow\n", function);
    abort();
}

size_t bionic_strlcpy(char *destination, const char *source, size_t size) {
    size_t length = strlen(source);
    if (size) {
        size_t copied = length < size - 1 ? length : size - 1;
        memcpy(destination, source, copied);
        destination[copied] = 0;
    }
    return length;
}

size_t bionic_strlcat(char *destination, const char *source, size_t size) {
    size_t existing = strnlen(destination, size);
    if (existing == size)
        return size + strlen(source);
    return existing + bionic_strlcpy(destination + existing, source, size - existing);
}

size_t bionic___strlen_chk(const char *string, size_t size) {
    size_t length = strlen(string);
    if (length >= size)
        overflow("strlen");
    return length;
}

char *bionic___strchr_chk(const char *string, int character, size_t size) {
    for (size_t index = 0; index < size; index++) {
        if (string[index] == (char)character)
            return (char *)string + index;
        if (!string[index])
            return NULL;
    }
    overflow("strchr");
}

char *bionic___strrchr_chk(const char *string, int character, size_t size) {
    if (strnlen(string, size) == size)
        overflow("strrchr");
    return strrchr(string, character);
}

char *bionic___strncpy_chk2(char *destination, const char *source, size_t count,
                            size_t destination_size, size_t source_size) {
    if (count > destination_size)
        overflow("strncpy");
    size_t length = strnlen(source, source_size < count ? source_size : count);
    memcpy(destination, source, length);
    memset(destination + length, 0, count - length);
    return destination;
}

size_t bionic___strlcpy_chk(char *destination, const char *source, size_t size, size_t real_size) {
    if (size > real_size)
        overflow("strlcpy");
    return bionic_strlcpy(destination, source, size);
}

size_t bionic___strlcat_chk(char *destination, const char *source, size_t size, size_t real_size) {
    if (size > real_size)
        overflow("strlcat");
    return bionic_strlcat(destination, source, size);
}

char *bionic___fgets_chk(char *buffer, int size, FILE *file, size_t real_size) {
    if (size < 0 || (size_t)size > real_size)
        overflow("fgets");
    return fgets(buffer, size, bionic_file(file));
}

ssize_t bionic___write_chk(int descriptor, const void *buffer, size_t count, size_t real_size) {
    if (count > real_size)
        overflow("write");
    return write(descriptor, buffer, count);
}

int bionic___vsnprintf_chk(char *destination, size_t supplied, int flags, size_t real_size,
                           const char *format, va_list arguments) {
    (void)flags;
    if (supplied > real_size)
        overflow("vsnprintf");
    return vsnprintf(destination, supplied, format, arguments);
}

int bionic___snprintf_chk(char *destination, size_t supplied, int flags, size_t real_size,
                          const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    int result = bionic___vsnprintf_chk(destination, supplied, flags, real_size, format, arguments);
    va_end(arguments);
    return result;
}

int bionic___vsprintf_chk(char *destination, int flags, size_t real_size, const char *format,
                          va_list arguments) {
    (void)flags;
    int result = vsnprintf(destination, real_size, format, arguments);
    if (result >= 0 && (size_t)result >= real_size)
        overflow("vsprintf");
    return result;
}

int bionic___sprintf_chk(char *destination, int flags, size_t real_size, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    int result = bionic___vsprintf_chk(destination, flags, real_size, format, arguments);
    va_end(arguments);
    return result;
}

static fd_set *checked_set(int descriptor, fd_set *set, size_t size) {
    if (descriptor < 0 || descriptor >= FD_SETSIZE || size < sizeof(fd_set))
        overflow("FD_SET");
    return set;
}

void bionic___FD_SET_chk(int descriptor, fd_set *set, size_t size) {
    FD_SET(descriptor, checked_set(descriptor, set, size));
}

void bionic___FD_CLR_chk(int descriptor, fd_set *set, size_t size) {
    FD_CLR(descriptor, checked_set(descriptor, set, size));
}

int bionic___FD_ISSET_chk(int descriptor, fd_set *set, size_t size) {
    return FD_ISSET(descriptor, checked_set(descriptor, set, size));
}

int bionic___open_2(const char *path, int flags) {
    return open(path, flags);
}

int bionic___openat_2(int directory, const char *path, int flags) {
    return openat(directory, path, flags);
}

int bionic___poll_chk(struct pollfd *descriptors, nfds_t count, int timeout, size_t real_size) {
    if (count > real_size / sizeof(*descriptors))
        overflow("poll");
    return poll(descriptors, count, timeout);
}

// glibc has __pread64_chk, in bionic's argument order, but no pwrite one.
ssize_t bionic___pwrite64_chk(int descriptor, const void *buffer, size_t count, off64_t offset,
                              size_t buffer_size) {
    if (count > buffer_size)
        overflow("pwrite64");
    return pwrite64(descriptor, buffer, count, offset);
}
