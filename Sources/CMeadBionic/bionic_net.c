#include "bionic_internal.h"

#include <netdb.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>

// bionic numbers getaddrinfo's flags and errors its own way, and its struct
// addrinfo has ai_canonname before ai_addr where glibc has them after. Both
// are the same size and type, so a result is swapped in place, and swapped
// back before glibc frees it.

_Static_assert(sizeof(struct addrinfo) == 48, "struct addrinfo differs only in field order");

static const struct { int bionic, host; } ai_flags[] = {
    { 0x0001, AI_PASSIVE },    { 0x0002, AI_CANONNAME }, { 0x0004, AI_NUMERICHOST },
    { 0x0008, AI_NUMERICSERV },{ 0x0800, AI_V4MAPPED },  { 0x0100, AI_ALL },
    { 0x0400, AI_ADDRCONFIG },
};

static const struct { int bionic, host; } ni_flags[] = {
    { 1, NI_NOFQDN }, { 2, NI_NUMERICHOST }, { 4, NI_NAMEREQD }, { 8, NI_NUMERICSERV },
    { 16, NI_DGRAM },
};

static const struct { int bionic, host; } errors[] = {
    { 1, EAI_ADDRFAMILY }, { 2, EAI_AGAIN },    { 3, EAI_BADFLAGS }, { 4, EAI_FAIL },
    { 5, EAI_FAMILY },     { 6, EAI_MEMORY },   { 7, EAI_NODATA },   { 8, EAI_NONAME },
    { 9, EAI_SERVICE },    { 10, EAI_SOCKTYPE },{ 11, EAI_SYSTEM },  { 14, EAI_OVERFLOW },
};

static int to_host_ai_flags(int flags) {
    int host = 0;
    for (size_t index = 0; index < sizeof(ai_flags) / sizeof(ai_flags[0]); index++)
        if (flags & ai_flags[index].bionic)
            host |= ai_flags[index].host;
    return host;
}

static int to_host_ni_flags(int flags) {
    int host = 0;
    for (size_t index = 0; index < sizeof(ni_flags) / sizeof(ni_flags[0]); index++)
        if (flags & ni_flags[index].bionic)
            host |= ni_flags[index].host;
    return host;
}

static int from_host_error(int error) {
    if (error == 0)
        return 0;
    for (size_t index = 0; index < sizeof(errors) / sizeof(errors[0]); index++)
        if (errors[index].host == error)
            return errors[index].bionic;
    return 4; // EAI_FAIL
}

static int to_host_error(int error) {
    for (size_t index = 0; index < sizeof(errors) / sizeof(errors[0]); index++)
        if (errors[index].bionic == error)
            return errors[index].host;
    return error;
}

static void swap_fields(struct addrinfo *list) {
    for (struct addrinfo *at = list; at; at = at->ai_next) {
        void *addr = at->ai_addr;
        at->ai_addr = (struct sockaddr *)at->ai_canonname;
        at->ai_canonname = addr;
    }
}

int bionic_getaddrinfo(const char *node, const char *service, const struct addrinfo *hints,
                       struct addrinfo **results) {
    struct addrinfo host_hints;
    if (hints) {
        // Only ai_flags to ai_protocol mean anything in hints, and those
        // come before the fields that differ.
        memset(&host_hints, 0, sizeof(host_hints));
        host_hints.ai_flags = to_host_ai_flags(hints->ai_flags);
        host_hints.ai_family = hints->ai_family;
        host_hints.ai_socktype = hints->ai_socktype;
        host_hints.ai_protocol = hints->ai_protocol;
    }
    int result = getaddrinfo(node, service, hints ? &host_hints : NULL, results);
    if (result == 0)
        swap_fields(*results);
    return from_host_error(result);
}

void bionic_freeaddrinfo(struct addrinfo *results) {
    swap_fields(results);
    freeaddrinfo(results);
}

const char *bionic_gai_strerror(int error) {
    return gai_strerror(to_host_error(error));
}

int bionic_getnameinfo(const struct sockaddr *address, socklen_t address_size, char *host,
                       socklen_t host_size, char *service, socklen_t service_size, int flags) {
    return from_host_error(getnameinfo(address, address_size, host, host_size, service,
                                       service_size, to_host_ni_flags(flags)));
}
