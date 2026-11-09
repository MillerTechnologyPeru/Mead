#include "bionic_internal.h"

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// bionic's sigset_t is one 64-bit word, the kernel's own; glibc's is 128
// bytes whose first word is that same word.
typedef uint64_t bionic_sigset;

static sigset_t to_host_set(bionic_sigset set) {
    sigset_t host;
    sigemptyset(&host);
    memcpy(&host, &set, sizeof(set));
    return host;
}

static bionic_sigset from_host_set(const sigset_t *host) {
    bionic_sigset set;
    memcpy(&set, host, sizeof(set));
    return set;
}

// And its sigaction leads with the flags.
typedef struct android_sigaction {
    int flags;
    void *handler;
    bionic_sigset mask;
    void (*restorer)(void);
} android_sigaction;
_Static_assert(sizeof(android_sigaction) == 32, "bionic's struct sigaction is 32 bytes");

int bionic_sigaction(int number, const android_sigaction *action, android_sigaction *old) {
    // Under MEAD_CRASH_REPORT a crash is Mead's to report: an app's crash
    // handler would hide where it happened.
    if (action && getenv("MEAD_CRASH_REPORT") &&
        (number == SIGSEGV || number == SIGBUS || number == SIGILL || number == SIGABRT || number == SIGFPE))
        return 0;
    struct sigaction host_action, host_old;
    memset(&host_action, 0, sizeof(host_action));
    memset(&host_old, 0, sizeof(host_old));
    if (action) {
        host_action.sa_flags = action->flags;
        host_action.sa_sigaction = (void (*)(int, siginfo_t *, void *))action->handler;
        host_action.sa_mask = to_host_set(action->mask);
    }
    int result = sigaction(number, action ? &host_action : NULL, old ? &host_old : NULL);
    if (result == 0 && old) {
        old->flags = host_old.sa_flags;
        old->handler = (void *)host_old.sa_sigaction;
        old->mask = from_host_set(&host_old.sa_mask);
        old->restorer = NULL;
    }
    return result;
}

static bool valid_signal(int number) {
    return number >= 1 && number <= 64;
}

int bionic_sigemptyset(bionic_sigset *set) {
    *set = 0;
    return 0;
}

int bionic_sigfillset(bionic_sigset *set) {
    *set = ~0ull;
    return 0;
}

int bionic_sigaddset(bionic_sigset *set, int number) {
    if (!valid_signal(number)) {
        errno = EINVAL;
        return -1;
    }
    *set |= 1ull << (number - 1);
    return 0;
}

int bionic_sigdelset(bionic_sigset *set, int number) {
    if (!valid_signal(number)) {
        errno = EINVAL;
        return -1;
    }
    *set &= ~(1ull << (number - 1));
    return 0;
}

int bionic_sigismember(const bionic_sigset *set, int number) {
    if (!valid_signal(number)) {
        errno = EINVAL;
        return -1;
    }
    return (*set >> (number - 1)) & 1;
}

int bionic_sigprocmask(int how, const bionic_sigset *set, bionic_sigset *old) {
    sigset_t host_set, host_old;
    if (set)
        host_set = to_host_set(*set);
    int result = sigprocmask(how, set ? &host_set : NULL, old ? &host_old : NULL);
    if (result == 0 && old)
        *old = from_host_set(&host_old);
    return result;
}

int bionic_pthread_sigmask(int how, const bionic_sigset *set, bionic_sigset *old) {
    sigset_t host_set, host_old;
    if (set)
        host_set = to_host_set(*set);
    int result = pthread_sigmask(how, set ? &host_set : NULL, old ? &host_old : NULL);
    if (result == 0 && old)
        *old = from_host_set(&host_old);
    return result;
}

int bionic_sigsuspend(const bionic_sigset *set) {
    sigset_t host_set = to_host_set(*set);
    return sigsuspend(&host_set);
}
