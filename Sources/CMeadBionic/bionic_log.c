#include "bionic_internal.h"

#include <signal.h>
#include <stdarg.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

// liblog.so and the system-property calls: formatted here, where variadics
// can be, and kept in Swift.

enum { LOG_LINE = 4096 }; // about what Android's logger keeps of one message

int bionic___android_log_write(int priority, const char *tag, const char *text) {
    mead_bionic_log_write(priority, tag, text);
    // MEAD_LOG_STACK=text, with MEAD_CRASH_REPORT: the first few times a
    // message holds that text, the frames of the code that wrote it.
    static int stacks_left = 3;
    const char *wanted = getenv("MEAD_LOG_STACK");
    if (wanted && *wanted && text && stacks_left > 0 && strstr(text, wanted)) {
        stacks_left--;
        syscall(SYS_tgkill, getpid(), (pid_t)syscall(SYS_gettid), SIGUSR2);
    }
    return 1;
}

int bionic___android_log_buf_write(int buffer, int priority, const char *tag, const char *text) {
    (void)buffer;
    return bionic___android_log_write(priority, tag, text);
}

int bionic___android_log_vprint(int priority, const char *tag, const char *format, va_list arguments) {
    char text[LOG_LINE];
    vsnprintf(text, sizeof(text), format, arguments);
    return bionic___android_log_write(priority, tag, text);
}

int bionic___android_log_print(int priority, const char *tag, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    int result = bionic___android_log_vprint(priority, tag, format, arguments);
    va_end(arguments);
    return result;
}

_Noreturn void bionic___android_log_assert(const char *condition, const char *tag,
                                           const char *format, ...) {
    char text[LOG_LINE] = "assertion failed";
    if (format) {
        va_list arguments;
        va_start(arguments, format);
        vsnprintf(text, sizeof(text), format, arguments);
        va_end(arguments);
    } else if (condition) {
        snprintf(text, sizeof(text), "assertion failed: %s", condition);
    }
    mead_bionic_log_write(7, tag, text);
    abort();
}

int bionic___android_log_is_loggable(int priority, const char *tag, int fallback) {
    (void)priority, (void)tag, (void)fallback;
    return 1;
}

int bionic___system_property_get(const char *name, char *value) {
    return mead_bionic_property_get(name, value);
}

const void *bionic___system_property_find(const char *name) {
    return mead_bionic_property_find(name);
}

int bionic___system_property_read(const void *property, char *name, char *value) {
    char local_name[32], local_value[92];
    mead_bionic_property_copy(property, name ? name : local_name, value ? value : local_value);
    return (int)strlen(value ? value : local_value);
}

void bionic___system_property_read_callback(const void *property,
                                            void (*callback)(void *, const char *, const char *, unsigned),
                                            void *cookie) {
    char name[32], value[92];
    mead_bionic_property_copy(property, name, value);
    callback(cookie, name, value, 0);
}

int bionic___system_property_foreach(void (*callback)(const void *, void *), void *cookie) {
    for (unsigned index = 0;; index++) {
        const void *property = mead_bionic_property_at(index);
        if (!property)
            return 0;
        callback(property, cookie);
    }
}
