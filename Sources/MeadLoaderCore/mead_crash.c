#define _GNU_SOURCE
#include "mead_loader.h"
#include "mead_dl.h"

#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>

// MEAD_CRASH_REPORT=1: where a crash happened, by library and offset, and
// who called it, for machines with no debugger. Good enough to read, and not
// async-signal-safe: it only runs on the way out.

static void print_address(const char *label, uint64_t address) {
    mead_dl_info info;
    memset(&info, 0, sizeof(info));
    if (address && mead_dladdr((const void *)(uintptr_t)address, &info) && info.dli_fname) {
        uint64_t offset = address - (uint64_t)(uintptr_t)info.dli_fbase;
        if (info.dli_sname)
            fprintf(stderr, "  %-4s 0x%lx  %s + 0x%lx (%s + 0x%lx)\n", label, (unsigned long)address, info.dli_fname,
                    (unsigned long)offset, info.dli_sname, (unsigned long)(address - (uint64_t)(uintptr_t)info.dli_saddr));
        else
            fprintf(stderr, "  %-4s 0x%lx  %s + 0x%lx\n", label, (unsigned long)address, info.dli_fname, (unsigned long)offset);
    } else {
        fprintf(stderr, "  %-4s 0x%lx\n", label, (unsigned long)address);
    }
}

// Whether a word can be read, asked of the kernel so that a bad frame
// pointer doesn't crash the crash report.
static bool readable(const void *address) {
    int descriptors[2];
    if (pipe(descriptors) != 0)
        return false;
    bool result = write(descriptors[1], address, 16) == 16;
    close(descriptors[0]);
    close(descriptors[1]);
    return result;
}

static void on_crash(int number, siginfo_t *information, void *context) {
    signal(number, SIG_DFL);
    const mcontext_t *machine = &((const ucontext_t *)context)->uc_mcontext;
    fprintf(stderr, "\nmead: crashed: signal %d, code %d, address %p, thread %ld\n", number, information->si_code,
            information->si_addr, (long)gettid());
    print_address("pc", machine->pc);
    print_address("lr", machine->regs[30]);
    for (int index = 0; index < 8; index++) {
        char name[8];
        snprintf(name, sizeof(name), "x%d", index);
        print_address(name, machine->regs[index]);
    }

    // Frame pointers, as far as they stay sane.
    uint64_t frame = machine->regs[29];
    for (int depth = 0; depth < 32 && frame >= 4096 && (frame & 7) == 0; depth++) {
        const uint64_t *record = (const uint64_t *)(uintptr_t)frame;
        char name[8];
        snprintf(name, sizeof(name), "#%d", depth);
        if (!readable(record))
            break;
        print_address(name, record[1]);
        if (record[0] <= frame)
            break;
        frame = record[0];
    }
    fflush(stderr);
    raise(number);
}

void mead_install_crash_report(void) {
    static char alternate[256 * 1024];
    stack_t stack = { .ss_sp = alternate, .ss_size = sizeof(alternate) };
    sigaltstack(&stack, NULL);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = on_crash;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    static const int signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE };
    for (size_t index = 0; index < sizeof(signals) / sizeof(signals[0]); index++)
        sigaction(signals[index], &action, NULL);
}
