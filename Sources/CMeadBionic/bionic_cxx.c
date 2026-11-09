#include "bionic_internal.h"

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>

// libstdc++.so: on Android a small system library, not the GNU one, with just
// what C++ needs from a C library: function-local static guards, and operator
// new and delete. A library that also has libc++ loaded gets that instead.

static pthread_mutex_t guard_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t guard_changed = PTHREAD_COND_INITIALIZER;

// A guard's first byte says it is done, as compilers test inline; its second
// that some thread is running the initializer.
int bionic___cxa_guard_acquire(uint8_t *guard) {
    pthread_mutex_lock(&guard_lock);
    while (guard[1] && !guard[0])
        pthread_cond_wait(&guard_changed, &guard_lock);
    int run = !guard[0];
    if (run)
        guard[1] = 1;
    pthread_mutex_unlock(&guard_lock);
    return run;
}

void bionic___cxa_guard_release(uint8_t *guard) {
    pthread_mutex_lock(&guard_lock);
    guard[0] = 1;
    guard[1] = 0;
    pthread_cond_broadcast(&guard_changed);
    pthread_mutex_unlock(&guard_lock);
}

void bionic___cxa_guard_abort(uint8_t *guard) {
    pthread_mutex_lock(&guard_lock);
    guard[1] = 0;
    pthread_cond_broadcast(&guard_changed);
    pthread_mutex_unlock(&guard_lock);
}

_Noreturn void bionic___cxa_pure_virtual(void) {
    fprintf(stderr, "mead: a pure virtual function was called\n");
    abort();
}

static void *allocate(size_t size) {
    void *memory = malloc(size ? size : 1);
    if (!memory)
        abort(); // no exceptions here to throw
    return memory;
}

void *bionic__Znwm(size_t size) { return allocate(size); }
void *bionic__Znam(size_t size) { return allocate(size); }
void bionic__ZdlPv(void *memory) { free(memory); }
void bionic__ZdaPv(void *memory) { free(memory); }
void bionic__ZdlPvm(void *memory, size_t size) { (void)size; free(memory); }
void bionic__ZdaPvm(void *memory, size_t size) { (void)size; free(memory); }
void *bionic__ZnwmRKSt9nothrow_t(size_t size, const void *tag) { (void)tag; return malloc(size ? size : 1); }
void *bionic__ZnamRKSt9nothrow_t(size_t size, const void *tag) { (void)tag; return malloc(size ? size : 1); }
void bionic__ZdlPvRKSt9nothrow_t(void *memory, const void *tag) { (void)tag; free(memory); }
void bionic__ZdaPvRKSt9nothrow_t(void *memory, const void *tag) { (void)tag; free(memory); }
