#include "bionic_internal.h"

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

// bionic's mutex is 40 bytes and glibc's 48, so glibc's lives on the heap and
// the Android one holds a pointer to it, made on first use. The first word
// keeps what Android's static initializers put there: the type, shifted 14.
//
// bionic's sync types are only 4-byte aligned, which arm64's atomics fault
// on for a pointer; the slot for that pointer is the first 8-aligned one at
// or after byte 8, which always fits in what is left.
#define SLOT(object) ((void *)(((uintptr_t)(object) + 8 + 7) & ~(uintptr_t)7))

typedef struct bionic_mutex {
    int32_t state;
    int32_t rest[9];
} bionic_mutex;
_Static_assert(sizeof(bionic_mutex) == 40, "bionic's pthread_mutex_t is 40 bytes");

static _Atomic(pthread_mutex_t *) *mutex_slot(bionic_mutex *mutex) {
    return SLOT(mutex);
}

static pthread_mutex_t *make_mutex(int type, const pthread_mutexattr_t *given) {
    pthread_mutex_t *mutex = malloc(sizeof(*mutex));
    if (!mutex)
        abort();
    if (given) {
        pthread_mutex_init(mutex, given);
        return mutex;
    }
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, type);
    pthread_mutex_init(mutex, &attr);
    pthread_mutexattr_destroy(&attr);
    return mutex;
}

static pthread_mutex_t *host_mutex(bionic_mutex *mutex) {
    pthread_mutex_t *host = atomic_load_explicit(mutex_slot(mutex), memory_order_acquire);
    if (host)
        return host;
    pthread_mutex_t *fresh = make_mutex((mutex->state >> 14) & 3, NULL);
    if (atomic_compare_exchange_strong_explicit(mutex_slot(mutex), &host, fresh, memory_order_acq_rel,
                                                memory_order_acquire))
        return fresh;
    pthread_mutex_destroy(fresh);
    free(fresh);
    return host;
}

int bionic_pthread_mutex_init(bionic_mutex *mutex, const pthread_mutexattr_t *attr) {
    memset(mutex, 0, sizeof(*mutex));
    atomic_store_explicit(mutex_slot(mutex), make_mutex(PTHREAD_MUTEX_NORMAL, attr), memory_order_release);
    return 0;
}

int bionic_pthread_mutex_destroy(bionic_mutex *mutex) {
    pthread_mutex_t *host = atomic_exchange_explicit(mutex_slot(mutex), NULL, memory_order_acq_rel);
    if (!host)
        return 0;
    int result = pthread_mutex_destroy(host);
    if (result == 0) {
        free(host);
        return 0;
    }
    atomic_store_explicit(mutex_slot(mutex), host, memory_order_release); // still locked: it stays
    return result;
}

int bionic_pthread_mutex_lock(bionic_mutex *mutex) {
    return pthread_mutex_lock(host_mutex(mutex));
}

int bionic_pthread_mutex_trylock(bionic_mutex *mutex) {
    return pthread_mutex_trylock(host_mutex(mutex));
}

int bionic_pthread_mutex_unlock(bionic_mutex *mutex) {
    return pthread_mutex_unlock(host_mutex(mutex));
}

int bionic_pthread_mutex_timedlock(bionic_mutex *mutex, const struct timespec *deadline) {
    return pthread_mutex_timedlock(host_mutex(mutex), deadline);
}

// Condition variables are the same size in both libraries, but glibc's does
// 64-bit atomics on the start of it, which a 4-byte-aligned Android one
// cannot take. So it too lives on the heap, made on first use. Bionic's
// static initializers are 0, or 2 for the monotonic clock.
typedef struct bionic_cond {
    int32_t state;
    int32_t rest[11];
} bionic_cond;
_Static_assert(sizeof(bionic_cond) == 48, "bionic's pthread_cond_t is 48 bytes");

enum { COND_MONOTONIC = 1 << 1 };

static _Atomic(pthread_cond_t *) *cond_slot(bionic_cond *cond) {
    return SLOT(cond);
}

static pthread_cond_t *make_cond(bool monotonic, const pthread_condattr_t *given) {
    pthread_cond_t *cond = malloc(sizeof(*cond));
    if (!cond)
        abort();
    if (given) {
        pthread_cond_init(cond, given);
    } else {
        pthread_condattr_t attr;
        pthread_condattr_init(&attr);
        if (monotonic)
            pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
        pthread_cond_init(cond, &attr);
        pthread_condattr_destroy(&attr);
    }
    return cond;
}

static pthread_cond_t *host_cond(bionic_cond *cond) {
    pthread_cond_t *host = atomic_load_explicit(cond_slot(cond), memory_order_acquire);
    if (host)
        return host;
    pthread_cond_t *fresh = make_cond(cond->state & COND_MONOTONIC, NULL);
    if (atomic_compare_exchange_strong_explicit(cond_slot(cond), &host, fresh, memory_order_acq_rel,
                                                memory_order_acquire))
        return fresh;
    pthread_cond_destroy(fresh);
    free(fresh);
    return host;
}

int bionic_pthread_cond_init(bionic_cond *cond, const pthread_condattr_t *attr) {
    memset(cond, 0, sizeof(*cond));
    atomic_store_explicit(cond_slot(cond), make_cond(false, attr), memory_order_release);
    return 0;
}

int bionic_pthread_cond_destroy(bionic_cond *cond) {
    pthread_cond_t *host = atomic_exchange_explicit(cond_slot(cond), NULL, memory_order_acq_rel);
    if (!host)
        return 0;
    int result = pthread_cond_destroy(host);
    free(host);
    return result;
}

int bionic_pthread_cond_signal(bionic_cond *cond) {
    return pthread_cond_signal(host_cond(cond));
}

int bionic_pthread_cond_broadcast(bionic_cond *cond) {
    return pthread_cond_broadcast(host_cond(cond));
}

int bionic_pthread_cond_wait(bionic_cond *cond, bionic_mutex *mutex) {
    return pthread_cond_wait(host_cond(cond), host_mutex(mutex));
}

int bionic_pthread_cond_timedwait(bionic_cond *cond, bionic_mutex *mutex,
                                  const struct timespec *deadline) {
    return pthread_cond_timedwait(host_cond(cond), host_mutex(mutex), deadline);
}

int bionic_pthread_cond_clockwait(bionic_cond *cond, bionic_mutex *mutex, clockid_t clock,
                                  const struct timespec *deadline) {
    return pthread_cond_clockwait(host_cond(cond), host_mutex(mutex), clock, deadline);
}

int bionic_pthread_cond_timedwait_monotonic_np(bionic_cond *cond, bionic_mutex *mutex,
                                               const struct timespec *deadline) {
    return pthread_cond_clockwait(host_cond(cond), host_mutex(mutex), CLOCK_MONOTONIC, deadline);
}

// bionic's attributes are kept here in its own 56 bytes, and only become
// glibc's at pthread_create.
typedef struct bionic_attr {
    uint32_t detached;
    uint32_t inherit;
    void *stack_base;
    size_t stack_size;
    size_t guard_size;
    int32_t policy;
    int32_t priority;
    char reserved[16];
} bionic_attr;
_Static_assert(sizeof(bionic_attr) == 56, "bionic's pthread_attr_t is 56 bytes");

enum { BIONIC_EXPLICIT_SCHED = 0, BIONIC_INHERIT_SCHED = 1 };
enum { DEFAULT_STACK = 1024 * 1024, DEFAULT_GUARD = 4096 };

int bionic_pthread_attr_init(bionic_attr *attr) {
    memset(attr, 0, sizeof(*attr));
    attr->stack_size = DEFAULT_STACK;
    attr->guard_size = DEFAULT_GUARD;
    attr->inherit = BIONIC_EXPLICIT_SCHED;
    return 0;
}

int bionic_pthread_attr_destroy(bionic_attr *attr) {
    memset(attr, 0, sizeof(*attr));
    return 0;
}

int bionic_pthread_attr_setdetachstate(bionic_attr *attr, int state) {
    if (state != PTHREAD_CREATE_DETACHED && state != PTHREAD_CREATE_JOINABLE)
        return EINVAL;
    attr->detached = state == PTHREAD_CREATE_DETACHED;
    return 0;
}

int bionic_pthread_attr_getdetachstate(const bionic_attr *attr, int *state) {
    *state = attr->detached ? PTHREAD_CREATE_DETACHED : PTHREAD_CREATE_JOINABLE;
    return 0;
}

int bionic_pthread_attr_setstacksize(bionic_attr *attr, size_t size) {
    if (size < PTHREAD_STACK_MIN)
        return EINVAL;
    attr->stack_size = size;
    return 0;
}

int bionic_pthread_attr_getstacksize(const bionic_attr *attr, size_t *size) {
    *size = attr->stack_size;
    return 0;
}

int bionic_pthread_attr_setstack(bionic_attr *attr, void *base, size_t size) {
    attr->stack_base = base;
    attr->stack_size = size;
    return 0;
}

int bionic_pthread_attr_getstack(const bionic_attr *attr, void **base, size_t *size) {
    *base = attr->stack_base;
    *size = attr->stack_size;
    return 0;
}

int bionic_pthread_attr_setguardsize(bionic_attr *attr, size_t size) {
    attr->guard_size = size;
    return 0;
}

int bionic_pthread_attr_getguardsize(const bionic_attr *attr, size_t *size) {
    *size = attr->guard_size;
    return 0;
}

int bionic_pthread_attr_setschedpolicy(bionic_attr *attr, int policy) {
    attr->policy = policy;
    return 0;
}

int bionic_pthread_attr_getschedpolicy(const bionic_attr *attr, int *policy) {
    *policy = attr->policy;
    return 0;
}

int bionic_pthread_attr_setschedparam(bionic_attr *attr, const struct sched_param *param) {
    attr->priority = param->sched_priority;
    return 0;
}

int bionic_pthread_attr_getschedparam(const bionic_attr *attr, struct sched_param *param) {
    param->sched_priority = attr->priority;
    return 0;
}

int bionic_pthread_attr_setinheritsched(bionic_attr *attr, int inherit) {
    if (inherit != BIONIC_EXPLICIT_SCHED && inherit != BIONIC_INHERIT_SCHED)
        return EINVAL;
    attr->inherit = (uint32_t)inherit;
    return 0;
}

int bionic_pthread_attr_getinheritsched(const bionic_attr *attr, int *inherit) {
    *inherit = (int)attr->inherit;
    return 0;
}

int bionic_pthread_getattr_np(pthread_t thread, bionic_attr *attr) {
    pthread_attr_t host;
    int result = pthread_getattr_np(thread, &host);
    if (result != 0)
        return result;
    bionic_pthread_attr_init(attr);
    int detach = PTHREAD_CREATE_JOINABLE;
    pthread_attr_getdetachstate(&host, &detach);
    attr->detached = detach == PTHREAD_CREATE_DETACHED;
    pthread_attr_getstack(&host, &attr->stack_base, &attr->stack_size);
    pthread_attr_getguardsize(&host, &attr->guard_size);
    pthread_attr_destroy(&host);
    return 0;
}

// The threads made here, for pthread_gettid_np on one that isn't the caller.
typedef struct known_thread {
    struct known_thread *next;
    pthread_t thread;
    pid_t tid;
} known_thread;

static pthread_mutex_t known_lock = PTHREAD_MUTEX_INITIALIZER;
static known_thread *known_threads;

static pid_t current_tid(void) {
    return (pid_t)syscall(SYS_gettid);
}

static void remember_this_thread(void) {
    known_thread *entry = malloc(sizeof(*entry));
    if (!entry)
        return;
    entry->thread = pthread_self();
    entry->tid = current_tid();
    pthread_mutex_lock(&known_lock);
    entry->next = known_threads;
    known_threads = entry;
    pthread_mutex_unlock(&known_lock);
}

static void forget_this_thread(void) {
    pthread_t self = pthread_self();
    pthread_mutex_lock(&known_lock);
    for (known_thread **at = &known_threads; *at; at = &(*at)->next) {
        if (pthread_equal((*at)->thread, self)) {
            known_thread *found = *at;
            *at = found->next;
            free(found);
            break;
        }
    }
    pthread_mutex_unlock(&known_lock);
}

pid_t bionic_pthread_gettid_np(pthread_t thread) {
    if (pthread_equal(thread, pthread_self()))
        return current_tid();
    pid_t tid = -1;
    pthread_mutex_lock(&known_lock);
    for (known_thread *at = known_threads; at; at = at->next)
        if (pthread_equal(at->thread, thread)) {
            tid = at->tid;
            break;
        }
    pthread_mutex_unlock(&known_lock);
    return tid;
}

// bionic keeps pthread_cleanup_push's records itself, in the caller's frame.
typedef struct bionic_cleanup {
    struct bionic_cleanup *previous;
    void (*routine)(void *);
    void *argument;
} bionic_cleanup;

static __thread bionic_cleanup *cleanups;

void bionic___pthread_cleanup_push(bionic_cleanup *record, void (*routine)(void *), void *argument) {
    record->previous = cleanups;
    record->routine = routine;
    record->argument = argument;
    cleanups = record;
}

void bionic___pthread_cleanup_pop(bionic_cleanup *record, int execute) {
    cleanups = record->previous;
    if (execute)
        record->routine(record->argument);
}

_Noreturn void bionic_pthread_exit(void *result) {
    while (cleanups)
        bionic___pthread_cleanup_pop(cleanups, 1);
    forget_this_thread();
    pthread_exit(result);
}

typedef struct thread_start {
    void *(*function)(void *);
    void *argument;
} thread_start;

static void *start_thread(void *raw) {
    thread_start start = *(thread_start *)raw;
    free(raw);
    if (bionic_loader)
        bionic_loader->thread_setup();
    remember_this_thread();
    void *result = start.function(start.argument);
    forget_this_thread();
    return result;
}

// Android asks for stacks by what it wants to use; here each one also holds
// the thread's static TLS, half a megabyte of which is the Android images'.
// A stack the caller allocated could not hold that, so it isn't used: the
// thread gets one of the size asked for. Scheduling attributes stay on the
// attr for the getters, as a real-time policy needs privileges a game on
// Linux does not have.
int bionic_pthread_create(pthread_t *thread, const bionic_attr *attr, void *(*function)(void *),
                          void *argument) {
    thread_start *start = malloc(sizeof(*start));
    if (!start)
        return EAGAIN;
    start->function = function;
    start->argument = argument;
    pthread_attr_t host;
    pthread_attr_t *given = NULL;
    if (attr) {
        pthread_attr_init(&host);
        pthread_attr_setdetachstate(&host, attr->detached ? PTHREAD_CREATE_DETACHED
                                                          : PTHREAD_CREATE_JOINABLE);
        size_t extra = bionic_loader ? bionic_loader->thread_tls_bytes : 0;
        pthread_attr_setstacksize(&host, attr->stack_size + extra);
        pthread_attr_setguardsize(&host, attr->guard_size);
        given = &host;
    }
    int result = pthread_create(thread, given, start_thread, start);
    if (given)
        pthread_attr_destroy(&host);
    if (result != 0)
        free(start);
    return result;
}

// bionic's sem_t is 16 bytes and glibc's 32; as with mutexes, glibc's lives
// on the heap, the pointer in the first 8-aligned slot of the 16.
typedef struct bionic_sem {
    int32_t words[4];
} bionic_sem;
_Static_assert(sizeof(bionic_sem) == 16, "bionic's sem_t is 16 bytes");

static _Atomic(sem_t *) *sem_slot(bionic_sem *sem) {
    return (void *)(((uintptr_t)sem + 7) & ~(uintptr_t)7);
}

static sem_t *host_sem(bionic_sem *sem) {
    return atomic_load_explicit(sem_slot(sem), memory_order_acquire);
}

int bionic_sem_init(bionic_sem *sem, int shared, unsigned value) {
    sem_t *host = malloc(sizeof(*host));
    if (!host) {
        errno = ENOMEM;
        return -1;
    }
    if (sem_init(host, shared, value) != 0) {
        free(host);
        return -1;
    }
    atomic_store_explicit(sem_slot(sem), host, memory_order_release);
    return 0;
}

int bionic_sem_destroy(bionic_sem *sem) {
    sem_t *host = atomic_exchange_explicit(sem_slot(sem), NULL, memory_order_acq_rel);
    if (!host) {
        errno = EINVAL;
        return -1;
    }
    int result = sem_destroy(host);
    free(host);
    return result;
}

int bionic_sem_post(bionic_sem *sem) {
    return sem_post(host_sem(sem));
}

int bionic_sem_wait(bionic_sem *sem) {
    return sem_wait(host_sem(sem));
}

int bionic_sem_trywait(bionic_sem *sem) {
    return sem_trywait(host_sem(sem));
}

int bionic_sem_timedwait(bionic_sem *sem, const struct timespec *deadline) {
    return sem_timedwait(host_sem(sem), deadline);
}

int bionic_sem_getvalue(bionic_sem *sem, int *value) {
    return sem_getvalue(host_sem(sem), value);
}

int bionic_pthread_atfork(void (*prepare)(void), void (*parent)(void), void (*child)(void)) {
    extern int __register_atfork(void (*)(void), void (*)(void), void (*)(void), void *);
    return __register_atfork(prepare, parent, child, NULL);
}
