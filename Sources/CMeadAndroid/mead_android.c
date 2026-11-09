#define _GNU_SOURCE
#include "mead_android.h"

#include <dirent.h>
#include <stdint.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>

static uint32_t to_epoll(int events) {
    uint32_t result = 0;
    if (events & MEAD_LOOPER_EVENT_INPUT)
        result |= EPOLLIN;
    if (events & MEAD_LOOPER_EVENT_OUTPUT)
        result |= EPOLLOUT;
    return result;
}

static int from_epoll(uint32_t events) {
    int result = 0;
    if (events & EPOLLIN)
        result |= MEAD_LOOPER_EVENT_INPUT;
    if (events & EPOLLOUT)
        result |= MEAD_LOOPER_EVENT_OUTPUT;
    if (events & EPOLLERR)
        result |= MEAD_LOOPER_EVENT_ERROR;
    if (events & EPOLLHUP)
        result |= MEAD_LOOPER_EVENT_HANGUP;
    return result;
}

int mead_poll_create(void) {
    return epoll_create1(EPOLL_CLOEXEC);
}

static int control(int poll_fd, int operation, int fd, int events) {
    struct epoll_event event = { .events = to_epoll(events), .data.fd = fd };
    return epoll_ctl(poll_fd, operation, fd, &event);
}

int mead_poll_add(int poll_fd, int fd, int events) {
    return control(poll_fd, EPOLL_CTL_ADD, fd, events);
}

int mead_poll_modify(int poll_fd, int fd, int events) {
    return control(poll_fd, EPOLL_CTL_MOD, fd, events);
}

int mead_poll_remove(int poll_fd, int fd) {
    return control(poll_fd, EPOLL_CTL_DEL, fd, 0);
}

int mead_poll_wait(int poll_fd, mead_poll_item *items, int capacity, int timeout) {
    struct epoll_event events[capacity];
    int count = epoll_wait(poll_fd, events, capacity, timeout);
    for (int index = 0; index < count; index++) {
        items[index].fd = events[index].data.fd;
        items[index].events = from_epoll(events[index].events);
    }
    return count;
}

int mead_event_create(void) {
    return eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
}

void mead_event_signal(int fd) {
    uint64_t one = 1;
    (void)!write(fd, &one, sizeof(one));
}

void mead_event_drain(int fd) {
    uint64_t counter;
    (void)!read(fd, &counter, sizeof(counter));
}

const char *mead_next_file_name(void *directory) {
    struct dirent *entry;
    while ((entry = readdir(directory)))
        if (entry->d_type == DT_REG)
            return entry->d_name;
    return NULL;
}
