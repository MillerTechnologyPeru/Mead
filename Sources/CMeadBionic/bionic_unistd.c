#include "bionic_internal.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>

// bionic numbers sysconf's and pathconf's names differently from glibc.
static int host_name(int bionic, bool path) {
    static const struct { int bionic, host; } sc[] = {
#define SC(value, name) { value, name },
#define PC(value, name)
#include "bionic_conf_names.inc"
#undef SC
#undef PC
    };
    static const struct { int bionic, host; } pc[] = {
#define SC(value, name)
#define PC(value, name) { value, name },
#include "bionic_conf_names.inc"
#undef SC
#undef PC
    };
    if (path) {
        for (size_t index = 0; index < sizeof(pc) / sizeof(pc[0]); index++)
            if (pc[index].bionic == bionic)
                return pc[index].host;
    } else {
        for (size_t index = 0; index < sizeof(sc) / sizeof(sc[0]); index++)
            if (sc[index].bionic == bionic)
                return sc[index].host;
    }
    return -1;
}

long bionic_sysconf(int name) {
    int host = host_name(name, false);
    if (host < 0) {
        errno = EINVAL;
        return -1;
    }
    return sysconf(host);
}

long bionic_pathconf(const char *path, int name) {
    int host = host_name(name, true);
    if (host < 0) {
        errno = EINVAL;
        return -1;
    }
    return pathconf(path, host);
}

long bionic_fpathconf(int descriptor, int name) {
    int host = host_name(name, true);
    if (host < 0) {
        errno = EINVAL;
        return -1;
    }
    return fpathconf(descriptor, host);
}

int bionic_atexit(void (*function)(void)) {
    extern int __cxa_atexit(void (*)(void *), void *, void *);
    return __cxa_atexit((void (*)(void *))function, NULL, NULL);
}

_Noreturn void bionic___assert2(const char *file, int line, const char *function,
                                const char *message) {
    char text[1024];
    snprintf(text, sizeof(text), "%s:%d: %s: assertion \"%s\" failed", file, line, function, message);
    mead_bionic_log_write(7, "libc", text);
    abort();
}

_Noreturn void bionic___assert(const char *file, int line, const char *message) {
    bionic___assert2(file, line, "?", message);
}

void bionic_android_set_abort_message(const char *message) {
    mead_bionic_log_write(7, "libc", message);
}

int bionic_android_get_device_api_level(void) {
    char value[92];
    return mead_bionic_property_get("ro.build.version.sdk", value) > 0 ? atoi(value) : -1;
}

// The classic table of character classes, with EOF's entry first: old inline
// ctype functions read it directly, through bionic's pointer to it.
enum { U = 0x01, L = 0x02, N = 0x04, S = 0x08, P = 0x10, C = 0x20, X = 0x40, B = 0x80 };
static char ctype_table[257];
const char *bionic__ctype_ = ctype_table;

__attribute__((constructor)) static void make_ctype_table(void) {
    for (int c = 0; c < 128; c++) {
        char flags = 0;
        if (c >= 'A' && c <= 'Z') flags |= U;
        if (c >= 'a' && c <= 'z') flags |= L;
        if (c >= '0' && c <= '9') flags |= N;
        if (c == ' ' || (c >= '\t' && c <= '\r')) flags |= S;
        if (c > ' ' && c < 127 && !isalnum(c)) flags |= P;
        if (c < ' ' || c == 127) flags |= C;
        if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f')) flags |= X;
        if (c == ' ') flags |= B;
        ctype_table[c + 1] = flags;
    }
}

// Android lets an app raise its threads' priority, down to nice -19 for
// audio; Linux lets an ordinary user go no lower than RLIMIT_NICE allows,
// which is usually not below where the thread is. Code written for Android
// takes a refusal as fatal (FMOD's mixer thread exits on it), so a raise
// goes as far as Linux allows and is reported done, as it would be there.
// A raise that is allowed, and every lowering, is the host's own answer.
int bionic_setpriority(int which, id_t who, int priority) {
    if (setpriority((__priority_which_t)which, who, priority) == 0)
        return 0;
    int error = errno;
    if (error != EACCES && error != EPERM) {
        errno = error;
        return -1;
    }
    errno = 0;
    int current = getpriority((__priority_which_t)which, who);
    if (errno != 0 || priority >= current) {
        errno = error;
        return -1;
    }
    struct rlimit limit;
    int floor = current;
    if (getrlimit(RLIMIT_NICE, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY && 20 - (int)limit.rlim_cur < current)
        floor = 20 - (int)limit.rlim_cur;
    int granted = priority > floor ? priority : floor;
    if (granted < current)
        setpriority((__priority_which_t)which, who, granted);
    const char *trace = getenv("MEAD_TRACE");
    if (trace && (strstr(trace, "bionic") || strstr(trace, "all")))
        fprintf(stderr, "mead(bionic): setpriority to %d refused; nice %d is as far as this user may go\n", priority,
                granted < current ? granted : current);
    return 0;
}

// bionic's basename is POSIX's, from <libgen.h>: "/usr/lib/" is "lib", and
// the path is never written to. glibc's plain basename is the GNU one, which
// says "" for a trailing slash. Answered in a buffer per thread, as bionic does.
char *bionic_basename(const char *path) {
    static __thread char buffer[4096];
    if (!path || !*path)
        return strcpy(buffer, ".");
    size_t end = strlen(path);
    while (end > 1 && path[end - 1] == '/')
        end--;
    // Only slashes: the root.
    if (end == 1 && path[0] == '/')
        return strcpy(buffer, "/");
    size_t start = end;
    while (start > 0 && path[start - 1] != '/')
        start--;
    size_t length = end - start;
    if (length >= sizeof(buffer)) {
        errno = ENAMETOOLONG;
        return NULL;
    }
    memcpy(buffer, path + start, length);
    buffer[length] = 0;
    return buffer;
}

mode_t bionic___umask_chk(mode_t mode) { return umask(mode); }

// A terminal's attributes, as bionic gets and sets them: the kernel's
// struct termios, which is smaller than glibc's (no speeds, 19 control
// characters), so glibc's own would write past an Android caller's.
int bionic_tcgetattr(int descriptor, void *attributes) {
    return ioctl(descriptor, TCGETS, attributes);
}

int bionic_tcsetattr(int descriptor, int when, const void *attributes) {
    unsigned long request;
    switch (when) {
    case TCSANOW: request = TCSETS; break;
    case TCSADRAIN: request = TCSETSW; break;
    case TCSAFLUSH: request = TCSETSF; break;
    default:
        errno = EINVAL;
        return -1;
    }
    return ioctl(descriptor, request, attributes);
}
