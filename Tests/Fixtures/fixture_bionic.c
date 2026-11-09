// mead --selftest's C half: every place bionic's ABI differs from glibc's,
// called as NDK code calls it. Returns the line of the first failure.

#define _GNU_SOURCE
#include <android/api-level.h>
#include <android/log.h>
#include <ctype.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <link.h>
#include <malloc.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <semaphore.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/system_properties.h>
#include <time.h>
#include <unistd.h>

#define CHECK(condition)                                                                   \
    do {                                                                                   \
        if (!(condition)) {                                                                \
            fprintf(stderr, "fixture_bionic: line %d: %s\n", __LINE__, #condition);        \
            return __LINE__;                                                               \
        }                                                                                  \
    } while (0)

extern char __sF[];

static int test_stdio(void) {
    FILE *old_stderr = (FILE *)(__sF + 2 * 152);
    CHECK(fileno(old_stderr) == 2);
    CHECK(fflush(old_stderr) == 0);
    FILE *file = tmpfile();
    CHECK(file != NULL);
    CHECK(fprintf(file, "%d-%s", 7, "seven") == 7);
    rewind(file);
    char line[16];
    CHECK(fgets(line, sizeof(line), file) != NULL);
    CHECK(strcmp(line, "7-seven") == 0);
    CHECK(fclose(file) == 0);
    return 0;
}

static volatile int signalled;

static void on_signal(int number, siginfo_t *info, void *context) {
    (void)context;
    signalled = number == SIGUSR1 && info->si_signo == SIGUSR1;
}

static int test_signals(void) {
    struct sigaction action, previous;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = on_signal;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    sigaddset(&action.sa_mask, SIGUSR2);
    CHECK(sigaction(SIGUSR1, &action, NULL) == 0);
    CHECK(raise(SIGUSR1) == 0);
    CHECK(signalled);

    CHECK(sigaction(SIGUSR1, NULL, &previous) == 0);
    CHECK(previous.sa_sigaction == on_signal);
    CHECK(previous.sa_flags & SA_SIGINFO);
    CHECK(sigismember(&previous.sa_mask, SIGUSR2) == 1);
    CHECK(sigismember(&previous.sa_mask, SIGUSR1) == 0);

    sigset_t block, before;
    sigemptyset(&block);
    sigaddset(&block, SIGUSR1);
    CHECK(sigprocmask(SIG_BLOCK, &block, &before) == 0);
    signalled = 0;
    raise(SIGUSR1);
    CHECK(!signalled);
    CHECK(sigprocmask(SIG_SETMASK, &before, NULL) == 0);
    CHECK(signalled);
    return 0;
}

// Audio threads raise their priority on Android; a Linux user usually may
// not, and that must not be the failure it would be taken for.
#include <sys/resource.h>
// bionic's smallest stack is 16 KB; FMOD asks for about 32 KB.
static void *small_stack_body(void *argument) {
    volatile char scratch[8 * 1024];
    scratch[0] = 1;
    scratch[sizeof(scratch) - 1] = 2;
    *(int *)argument = scratch[0] + scratch[sizeof(scratch) - 1];
    return NULL;
}

static int test_small_stacks(void) {
    pthread_attr_t attr;
    CHECK(pthread_attr_init(&attr) == 0);
    CHECK(pthread_attr_setstacksize(&attr, 8 * 1024) == EINVAL);
    CHECK(pthread_attr_setstacksize(&attr, 16 * 1024) == 0);
    CHECK(pthread_attr_setstacksize(&attr, 32 * 1024) == 0);
    pthread_t thread;
    int result = 0;
    CHECK(pthread_create(&thread, &attr, small_stack_body, &result) == 0);
    CHECK(pthread_join(thread, NULL) == 0);
    CHECK(result == 3);
    pthread_attr_destroy(&attr);
    return 0;
}

static int test_priority(void) {
    CHECK(setpriority(PRIO_PROCESS, 0, -16) == 0);
    CHECK(setpriority(PRIO_PROCESS, 0, 5) == 0);
    CHECK(getpriority(PRIO_PROCESS, 0) == 5);
    CHECK(setpriority(PRIO_PROCESS, -1, 0) == -1);
    return 0;
}

static int test_sysconf(void) {
    CHECK(sysconf(_SC_PAGESIZE) == getpagesize());
    CHECK(sysconf(_SC_NPROCESSORS_ONLN) >= 1);
    CHECK(sysconf(_SC_CLK_TCK) == 100);
    CHECK(pathconf("/", _PC_NAME_MAX) == 255);
    return 0;
}

static int test_addrinfo(void) {
    struct addrinfo hints, *result = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV;
    CHECK(getaddrinfo("127.0.0.1", "80", &hints, &result) == 0);
    CHECK(result != NULL);
    CHECK(result->ai_family == AF_INET);
    CHECK(result->ai_canonname == NULL);
    CHECK(result->ai_addr != NULL);
    struct sockaddr_in *address = (struct sockaddr_in *)result->ai_addr;
    CHECK(address->sin_family == AF_INET);
    CHECK(ntohs(address->sin_port) == 80);
    CHECK(ntohl(address->sin_addr.s_addr) == 0x7f000001);
    freeaddrinfo(result);

    CHECK(getaddrinfo("not a host", "80", &hints, &result) == EAI_NONAME);
    CHECK(strlen(gai_strerror(EAI_NONAME)) > 0);
    return 0;
}

static pid_t thread_tid;
static int cleaned;

static void cleanup(void *argument) {
    cleaned = *(int *)argument;
}

static void *thread_body(void *argument) {
    thread_tid = pthread_gettid_np(pthread_self());
    int value = 23;
    pthread_cleanup_push(cleanup, &value);
    pthread_cleanup_pop(1);
    return argument;
}

static int test_threads(void) {
    pthread_attr_t attr;
    size_t size = 0;
    CHECK(pthread_attr_init(&attr) == 0);
    CHECK(pthread_attr_setstacksize(&attr, 128 * 1024) == 0);
    CHECK(pthread_attr_getstacksize(&attr, &size) == 0);
    CHECK(size == 128 * 1024);
    CHECK(pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_JOINABLE) == 0);
    pthread_t thread;
    int token = 0;
    int created = pthread_create(&thread, &attr, thread_body, &token);
    if (created != 0)
        fprintf(stderr, "fixture_bionic: pthread_create: %s\n", strerror(created));
    CHECK(created == 0);
    void *result = NULL;
    CHECK(pthread_join(thread, &result) == 0);
    CHECK(result == &token);
    CHECK(thread_tid > 0 && thread_tid != gettid());
    CHECK(cleaned == 23);
    CHECK(pthread_attr_destroy(&attr) == 0);

    pthread_attr_t own;
    void *base = NULL;
    CHECK(pthread_getattr_np(pthread_self(), &own) == 0);
    CHECK(pthread_attr_getstack(&own, &base, &size) == 0);
    CHECK(base != NULL && size > 0);
    CHECK(pthread_attr_destroy(&own) == 0);
    CHECK(pthread_gettid_np(pthread_self()) == gettid());
    return 0;
}

static int test_mutexes(void) {
    pthread_mutex_t plain = PTHREAD_MUTEX_INITIALIZER;
    CHECK(pthread_mutex_lock(&plain) == 0);
    CHECK(pthread_mutex_trylock(&plain) == EBUSY);
    CHECK(pthread_mutex_unlock(&plain) == 0);
    CHECK(pthread_mutex_destroy(&plain) == 0);

    pthread_mutex_t checked = PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP;
    CHECK(pthread_mutex_lock(&checked) == 0);
    CHECK(pthread_mutex_lock(&checked) == EDEADLK);
    CHECK(pthread_mutex_unlock(&checked) == 0);

    pthread_mutexattr_t attr;
    pthread_mutex_t recursive;
    CHECK(pthread_mutexattr_init(&attr) == 0);
    CHECK(pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE) == 0);
    CHECK(pthread_mutex_init(&recursive, &attr) == 0);
    CHECK(pthread_mutex_lock(&recursive) == 0);
    CHECK(pthread_mutex_lock(&recursive) == 0);
    CHECK(pthread_mutex_unlock(&recursive) == 0);
    CHECK(pthread_mutex_unlock(&recursive) == 0);
    CHECK(pthread_mutex_destroy(&recursive) == 0);

    pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_nsec += 1000000;
    if (deadline.tv_nsec >= 1000000000) {
        deadline.tv_nsec -= 1000000000;
        deadline.tv_sec++;
    }
    CHECK(pthread_mutex_lock(&mutex) == 0);
    CHECK(pthread_cond_timedwait(&cond, &mutex, &deadline) == ETIMEDOUT);
    CHECK(pthread_mutex_unlock(&mutex) == 0);

    sem_t semaphore;
    CHECK(sem_init(&semaphore, 0, 0) == 0);
    CHECK(sem_trywait(&semaphore) == -1 && errno == EAGAIN);
    CHECK(sem_post(&semaphore) == 0);
    CHECK(sem_wait(&semaphore) == 0);
    CHECK(sem_destroy(&semaphore) == 0);
    return 0;
}

static int test_memory_and_jumps(void) {
    jmp_buf jump;
    volatile int count = 0;
    if (setjmp(jump) == 0) {
        count = 1;
        longjmp(jump, 5);
    } else {
        count++;
    }
    CHECK(count == 2);

    void *block = malloc(4096);
    CHECK(block != NULL);
    struct mallinfo information = mallinfo();
    CHECK(information.uordblks >= 4096);
    free(block);
    return 0;
}

// strerror_r under its own name is POSIX's, as code built without _GNU_SOURCE
// (libc++, for one) calls it.
extern int posix_strerror_r(int number, char *buffer, size_t size) __asm__("strerror_r");

static int test_strings_and_files(void) {
    char message[64];
    CHECK(posix_strerror_r(ENOENT, message, sizeof(message)) == 0);
    CHECK(strcmp(message, "No such file or directory") == 0);
    CHECK(strcmp(strerror_r(ENOENT, message, sizeof(message)), "No such file or directory") == 0);

    char buffer[8];
    CHECK(strlcpy(buffer, "abcdefghij", sizeof(buffer)) == 10);
    CHECK(strcmp(buffer, "abcdefg") == 0);
    strlcpy(buffer, "ab", sizeof(buffer));
    CHECK(strlcat(buffer, "cd", sizeof(buffer)) == 4);
    CHECK(strlen(buffer) == 4); // __strlen_chk under fortify
    char copy[16];
    memcpy(copy, buffer, strlen(buffer) + 1); // __memcpy_chk
    CHECK(strrchr(copy, 'c') == copy + 2);    // __strrchr_chk
    int written = snprintf(copy, sizeof(copy), "%d", 1234);
    CHECK(written == 4);

    CHECK(_ctype_['a' + 1] & 2);
    CHECK(_ctype_['A' + 1] & 1);
    CHECK(_ctype_['7' + 1] & 4);
    CHECK(!(_ctype_['z' + 1] & 0x40));

    CHECK(open("/no/such/file", O_RDONLY) == -1 && errno == ENOENT);

    struct stat status;
    CHECK(stat("/", &status) == 0);
    CHECK(S_ISDIR(status.st_mode));
    DIR *directory = opendir("/");
    CHECK(directory != NULL);
    CHECK(readdir(directory) != NULL);
    CHECK(closedir(directory) == 0);
    return 0;
}

// What Android's libstdc++.so has for C++ code to call.
int __cxa_guard_acquire(unsigned long long *guard);
void __cxa_guard_release(unsigned long long *guard);
void __cxa_guard_abort(unsigned long long *guard);
void *_Znwm(size_t size);
void _ZdlPv(void *memory);

static int test_libstdcxx(void) {
    unsigned long long guard = 0;
    CHECK(__cxa_guard_acquire(&guard) == 1);
    __cxa_guard_abort(&guard);
    CHECK(*(unsigned char *)&guard == 0);
    CHECK(__cxa_guard_acquire(&guard) == 1);
    __cxa_guard_release(&guard);
    CHECK(*(unsigned char *)&guard == 1);
    CHECK(__cxa_guard_acquire(&guard) == 0);
    void *memory = _Znwm(32);
    CHECK(memory != NULL);
    _ZdlPv(memory);
    return 0;
}

static int visited_properties;

static void visit_property(const prop_info *property, void *cookie) {
    (void)property;
    ++*(int *)cookie;
}

static int test_android_services(void) {
    char value[PROP_VALUE_MAX], name[PROP_NAME_MAX];
    CHECK(__system_property_get("ro.product.cpu.abi", value) > 0);
    CHECK(strcmp(value, "arm64-v8a") == 0);
    CHECK(__system_property_get("ro.mead.no.such.property", value) == 0);
    CHECK(value[0] == 0);
    const prop_info *property = __system_property_find("ro.build.version.sdk");
    CHECK(property != NULL);
    CHECK(__system_property_read(property, name, value) > 0);
    CHECK(strcmp(name, "ro.build.version.sdk") == 0);
    CHECK(atoi(value) >= 21);
    CHECK(__system_property_find("ro.mead.no.such.property") == NULL);
    CHECK(__system_property_foreach(visit_property, &visited_properties) == 0);
    CHECK(visited_properties > 0);

    CHECK(__android_log_print(ANDROID_LOG_INFO, "fixture_bionic", "logging %s", "works") > 0);
    CHECK(__android_log_write(ANDROID_LOG_DEBUG, "fixture_bionic", "and plainly") > 0);
    return 0;
}

static int found_self;

static int visit_image(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size, (void)data;
    if (info->dlpi_name && strstr(info->dlpi_name, "libfixture_bionic.so") && info->dlpi_phnum > 0)
        found_self = 1;
    return 0;
}

static int test_dynamic_linker(void) {
    void *self = dlopen(NULL, RTLD_NOW);
    CHECK(self != NULL);
    CHECK(dlsym(self, "mead_selftest") != NULL);
    CHECK(dlsym(RTLD_DEFAULT, "mead_selftest") != NULL);
    CHECK(dlsym(RTLD_DEFAULT, "mead_no_such_symbol") == NULL);
    CHECK(dlerror() != NULL);
    CHECK(dlerror() == NULL);

    void *libc = dlopen("libc.so", RTLD_NOW);
    CHECK(libc != NULL);
    size_t (*length)(const char *) = dlsym(libc, "strlen");
    CHECK(length != NULL && length("four") == 4);

    Dl_info info;
    CHECK(dladdr((void *)test_dynamic_linker, &info) != 0);
    CHECK(strstr(info.dli_fname, "libfixture_bionic.so") != NULL);

    dl_iterate_phdr(visit_image, NULL);
    CHECK(found_self);
    return 0;
}

int mead_selftest(void) {
    int (*const tests[])(void) = {
        test_stdio,    test_signals,          test_sysconf,           test_addrinfo,
        test_threads,  test_mutexes,          test_memory_and_jumps,  test_strings_and_files,
        test_android_services, test_dynamic_linker,    test_libstdcxx,         test_priority,          test_small_stacks,
    };
    for (size_t index = 0; index < sizeof(tests) / sizeof(tests[0]); index++) {
        int failed = tests[index]();
        if (failed)
            return failed;
    }
    return 0;
}
