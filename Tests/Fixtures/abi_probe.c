// Prints the layouts and constants of the libc ABI, one per line. Built
// once against bionic and once against glibc, the diff of the two outputs
// is exactly what MeadBionic has to translate.

#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <link.h>
#include <locale.h>
#include <malloc.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <semaphore.h>
#include <setjmp.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/auxv.h>
#include <sys/epoll.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>
#include <utime.h>
#include <wchar.h>

#define SIZE(type) printf("sizeof %s %zu\n", #type, sizeof(type))
#define FIELD(type, field) printf("offsetof %s.%s %zu\n", #type, #field, offsetof(type, field))
#define ALIGN(type) printf("alignof %s %zu\n", #type, _Alignof(type))
#define VALUE(name) printf("value %s %lld\n", #name, (long long)(name))

int main(void) {
    ALIGN(pthread_mutex_t);
    ALIGN(pthread_mutexattr_t);
    ALIGN(pthread_cond_t);
    ALIGN(pthread_condattr_t);
    ALIGN(pthread_rwlock_t);
    ALIGN(pthread_attr_t);
    ALIGN(pthread_spinlock_t);
    ALIGN(sem_t);
    ALIGN(sigset_t);
    ALIGN(jmp_buf);
    SIZE(pthread_t);
    SIZE(pthread_spinlock_t);
    SIZE(pthread_mutex_t);
    SIZE(pthread_mutexattr_t);
    SIZE(pthread_cond_t);
    SIZE(pthread_condattr_t);
    SIZE(pthread_rwlock_t);
    SIZE(pthread_rwlockattr_t);
    SIZE(pthread_attr_t);
    SIZE(pthread_once_t);
    SIZE(pthread_key_t);
    SIZE(sem_t);
    SIZE(sigset_t);
    SIZE(jmp_buf);
    SIZE(mbstate_t);
    SIZE(fd_set);
    SIZE(cpu_set_t);
    SIZE(off_t);
    SIZE(wchar_t);
    SIZE(long double);

    SIZE(struct sigaction);
    FIELD(struct sigaction, sa_handler);
    FIELD(struct sigaction, sa_mask);
    FIELD(struct sigaction, sa_flags);
    SIZE(struct stat);
    FIELD(struct stat, st_dev);
    FIELD(struct stat, st_ino);
    FIELD(struct stat, st_mode);
    FIELD(struct stat, st_nlink);
    FIELD(struct stat, st_uid);
    FIELD(struct stat, st_gid);
    FIELD(struct stat, st_rdev);
    FIELD(struct stat, st_size);
    FIELD(struct stat, st_blksize);
    FIELD(struct stat, st_blocks);
    FIELD(struct stat, st_atim);
    FIELD(struct stat, st_mtim);
    FIELD(struct stat, st_ctim);
    SIZE(struct statvfs);
    FIELD(struct statvfs, f_bsize);
    FIELD(struct statvfs, f_frsize);
    FIELD(struct statvfs, f_blocks);
    FIELD(struct statvfs, f_bfree);
    FIELD(struct statvfs, f_bavail);
    FIELD(struct statvfs, f_files);
    FIELD(struct statvfs, f_ffree);
    FIELD(struct statvfs, f_favail);
    FIELD(struct statvfs, f_fsid);
    FIELD(struct statvfs, f_flag);
    FIELD(struct statvfs, f_namemax);
    SIZE(struct dirent);
    FIELD(struct dirent, d_ino);
    FIELD(struct dirent, d_off);
    FIELD(struct dirent, d_reclen);
    FIELD(struct dirent, d_type);
    FIELD(struct dirent, d_name);
    SIZE(struct tm);
    FIELD(struct tm, tm_isdst);
    FIELD(struct tm, tm_gmtoff);
    FIELD(struct tm, tm_zone);
    SIZE(struct timespec);
    SIZE(struct timeval);
    SIZE(struct rlimit);
    SIZE(struct rusage);
    SIZE(struct addrinfo);
    FIELD(struct addrinfo, ai_flags);
    FIELD(struct addrinfo, ai_addrlen);
    FIELD(struct addrinfo, ai_canonname);
    FIELD(struct addrinfo, ai_addr);
    FIELD(struct addrinfo, ai_next);
    SIZE(struct hostent);
    FIELD(struct hostent, h_name);
    FIELD(struct hostent, h_aliases);
    FIELD(struct hostent, h_addrtype);
    FIELD(struct hostent, h_length);
    FIELD(struct hostent, h_addr_list);
    SIZE(struct msghdr);
    FIELD(struct msghdr, msg_control);
    FIELD(struct msghdr, msg_controllen);
    FIELD(struct msghdr, msg_flags);
    SIZE(struct cmsghdr);
    SIZE(struct epoll_event);
    SIZE(struct pollfd);
    SIZE(struct sched_param);
    SIZE(struct utsname);
    SIZE(struct utimbuf);
    SIZE(struct lconv);
    FIELD(struct lconv, decimal_point);
    FIELD(struct lconv, thousands_sep);
    FIELD(struct lconv, grouping);
    FIELD(struct lconv, int_curr_symbol);
    FIELD(struct lconv, negative_sign);
    FIELD(struct lconv, int_frac_digits);
    SIZE(struct mallinfo);
    SIZE(struct dl_phdr_info);
    FIELD(struct dl_phdr_info, dlpi_addr);
    FIELD(struct dl_phdr_info, dlpi_name);
    FIELD(struct dl_phdr_info, dlpi_phdr);
    FIELD(struct dl_phdr_info, dlpi_phnum);
    SIZE(Dl_info);

    VALUE(_SC_ARG_MAX);
    VALUE(_SC_CHILD_MAX);
    VALUE(_SC_CLK_TCK);
    VALUE(_SC_NGROUPS_MAX);
    VALUE(_SC_OPEN_MAX);
    VALUE(_SC_PAGESIZE);
    VALUE(_SC_PAGE_SIZE);
    VALUE(_SC_NPROCESSORS_CONF);
    VALUE(_SC_NPROCESSORS_ONLN);
    VALUE(_SC_PHYS_PAGES);
    VALUE(_SC_AVPHYS_PAGES);
    VALUE(_SC_GETPW_R_SIZE_MAX);
    VALUE(_SC_GETGR_R_SIZE_MAX);
    VALUE(_SC_THREAD_STACK_MIN);
    VALUE(_SC_IOV_MAX);
    VALUE(_SC_HOST_NAME_MAX);
    VALUE(_SC_NPROCESSORS_ONLN);
    VALUE(_PC_NAME_MAX);
    VALUE(_PC_PATH_MAX);
    VALUE(_PC_LINK_MAX);
    VALUE(_PC_PIPE_BUF);
    VALUE(_PC_FILESIZEBITS);
    VALUE(_PC_NO_TRUNC);

    VALUE(AI_PASSIVE);
    VALUE(AI_CANONNAME);
    VALUE(AI_NUMERICHOST);
    VALUE(AI_NUMERICSERV);
    VALUE(AI_V4MAPPED);
    VALUE(AI_ALL);
    VALUE(AI_ADDRCONFIG);
    VALUE(EAI_BADFLAGS);
    VALUE(EAI_NONAME);
    VALUE(EAI_AGAIN);
    VALUE(EAI_FAIL);
    VALUE(EAI_FAMILY);
    VALUE(EAI_SOCKTYPE);
    VALUE(EAI_SERVICE);
    VALUE(EAI_MEMORY);
    VALUE(EAI_SYSTEM);
    VALUE(EAI_OVERFLOW);
    VALUE(NI_NUMERICHOST);
    VALUE(NI_NUMERICSERV);
    VALUE(NI_NOFQDN);
    VALUE(NI_NAMEREQD);
    VALUE(NI_DGRAM);

    VALUE(LC_CTYPE);
    VALUE(LC_NUMERIC);
    VALUE(LC_TIME);
    VALUE(LC_COLLATE);
    VALUE(LC_MONETARY);
    VALUE(LC_MESSAGES);
    VALUE(LC_ALL);
    VALUE(LC_CTYPE_MASK);
    VALUE(LC_NUMERIC_MASK);
    VALUE(LC_TIME_MASK);
    VALUE(LC_COLLATE_MASK);
    VALUE(LC_MONETARY_MASK);
    VALUE(LC_MESSAGES_MASK);
    VALUE(LC_ALL_MASK);

    VALUE(PTHREAD_MUTEX_NORMAL);
    VALUE(PTHREAD_MUTEX_RECURSIVE);
    VALUE(PTHREAD_MUTEX_ERRORCHECK);
    VALUE(PTHREAD_CREATE_JOINABLE);
    VALUE(PTHREAD_CREATE_DETACHED);
    VALUE(PTHREAD_PROCESS_PRIVATE);
    VALUE(PTHREAD_PROCESS_SHARED);
    VALUE(PTHREAD_EXPLICIT_SCHED);
    VALUE(PTHREAD_INHERIT_SCHED);
    VALUE(SCHED_OTHER);
    VALUE(SCHED_FIFO);
    VALUE(SCHED_RR);

    VALUE(O_RDONLY);
    VALUE(O_WRONLY);
    VALUE(O_RDWR);
    VALUE(O_CREAT);
    VALUE(O_EXCL);
    VALUE(O_TRUNC);
    VALUE(O_APPEND);
    VALUE(O_NONBLOCK);
    VALUE(O_DIRECTORY);
    VALUE(O_NOFOLLOW);
    VALUE(O_CLOEXEC);
    VALUE(F_GETFD);
    VALUE(F_SETFD);
    VALUE(F_GETFL);
    VALUE(F_SETFL);
    VALUE(F_GETLK);
    VALUE(F_SETLK);
    VALUE(F_SETLKW);
    VALUE(MAP_SHARED);
    VALUE(MAP_PRIVATE);
    VALUE(MAP_FIXED);
    VALUE(MAP_ANONYMOUS);
    VALUE(MAP_NORESERVE);
    VALUE(MADV_DONTNEED);
    VALUE(MREMAP_MAYMOVE);
    VALUE(RLIMIT_CORE);
    VALUE(RLIMIT_NOFILE);
    VALUE(RLIMIT_STACK);
    VALUE(RLIMIT_AS);
    VALUE(RUSAGE_SELF);
    VALUE(RUSAGE_THREAD);
    VALUE(CLOCK_REALTIME);
    VALUE(CLOCK_MONOTONIC);
    VALUE(CLOCK_BOOTTIME);
    VALUE(AT_HWCAP);
    VALUE(AT_HWCAP2);
    VALUE(AT_PAGESZ);
    VALUE(AT_RANDOM);
    VALUE(RTLD_LAZY);
    VALUE(RTLD_NOW);
    VALUE(RTLD_GLOBAL);
    VALUE(RTLD_LOCAL);
    VALUE(RTLD_NOLOAD);
    VALUE(RTLD_NODELETE);
    printf("pointer RTLD_DEFAULT %p\n", RTLD_DEFAULT);
    printf("pointer RTLD_NEXT %p\n", RTLD_NEXT);

    VALUE(SIG_BLOCK);
    VALUE(SIG_UNBLOCK);
    VALUE(SIG_SETMASK);
    VALUE(SA_SIGINFO);
    VALUE(SA_RESTART);
    VALUE(SA_NODEFER);
    VALUE(SA_RESETHAND);
    VALUE(SA_ONSTACK);
    VALUE(SIGABRT);
    VALUE(SIGSEGV);
    VALUE(SIGPIPE);
    VALUE(SIGUSR1);
    VALUE(SOL_SOCKET);
    VALUE(SO_REUSEADDR);
    VALUE(SO_KEEPALIVE);
    VALUE(SO_BROADCAST);
    VALUE(SO_RCVBUF);
    VALUE(SO_SNDBUF);
    VALUE(SO_ERROR);
    VALUE(MSG_NOSIGNAL);
    VALUE(MSG_DONTWAIT);
    VALUE(MSG_PEEK);
    VALUE(SOCK_STREAM);
    VALUE(SOCK_DGRAM);
    VALUE(SOCK_NONBLOCK);
    VALUE(SOCK_CLOEXEC);
    VALUE(AF_INET);
    VALUE(AF_INET6);
    VALUE(EPOLLIN);
    VALUE(EPOLLOUT);
    VALUE(EPOLL_CTL_ADD);

    VALUE(EAGAIN);
    VALUE(EINTR);
    VALUE(EINVAL);
    VALUE(ENOENT);
    VALUE(ENOSYS);
    VALUE(ETIMEDOUT);
    VALUE(ECONNRESET);
    VALUE(EINPROGRESS);
    VALUE(EWOULDBLOCK);
    VALUE(EOVERFLOW);
    VALUE(EDEADLK);
    VALUE(EBUSY);

    VALUE(SEEK_SET);
    VALUE(SEEK_CUR);
    VALUE(SEEK_END);
    VALUE(_IOFBF);
    VALUE(_IOLBF);
    VALUE(_IONBF);
    VALUE(BUFSIZ);
    VALUE(EOF);
    return 0;
}
