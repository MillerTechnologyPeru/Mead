#define _GNU_SOURCE
#include "mead_loader.h"
#include "mead_deps.h"
#include "mead_dl.h"

#include <ctype.h>
#include <dirent.h>
#include <dlfcn.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
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

// What a value points at, if that is text.
static void print_text(uint64_t address) {
    if (address < 4096 || !readable((const void *)(uintptr_t)address))
        return;
    const char *text = (const char *)(uintptr_t)address;
    int length = 0;
    while (length < 15 && isprint((unsigned char)text[length]))
        length++;
    if (length < 4)
        return;
    // As much as can safely be read, a page's end being the only limit.
    uint64_t room = 4096 - (address & 4095);
    int limit = room < 120 ? (int)room : 120;
    while (length < limit && isprint((unsigned char)text[length]))
        length++;
    fprintf(stderr, "    -> \"%.*s\"\n", length, text);
}

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

static void on_crash(int number, siginfo_t *information, void *context) {
    signal(number, SIG_DFL);
    const mcontext_t *machine = &((const ucontext_t *)context)->uc_mcontext;
    fprintf(stderr, "\nmead: crashed: signal %d, code %d, address %p, thread %ld\n", number, information->si_code,
            information->si_addr, (long)gettid());
    char thread_name[17] = { 0 };
    prctl(PR_GET_NAME, thread_name);
    fprintf(stderr, "  thread name: %s\n", thread_name);
    print_address("pc", machine->pc);
    print_address("lr", machine->regs[30]);
    fprintf(stderr, "  sp   0x%lx\n", (unsigned long)machine->sp);
    for (int index = 0; index < 29; index++) {
        const mead_image *image = mead_deps_image_for((const void *)(uintptr_t)machine->regs[index]);
        if (image)
            fprintf(stderr, "  x%-2d  0x%lx  %s + 0x%lx\n", index, (unsigned long)machine->regs[index], image->path,
                    (unsigned long)(machine->regs[index] - image->load_bias));
        else
            fprintf(stderr, "  x%-2d  0x%lx\n", index, (unsigned long)machine->regs[index]);
        print_text(machine->regs[index]);
    }
    fflush(stderr);

    // MEAD_CRASH_DUMP=x1: the words a register points at, and what they point
    // at in turn, for reading a structure no debugger is here to show.
    const char *dump = getenv("MEAD_CRASH_DUMP");
    if (dump && dump[0] == 'x') {
        int which = atoi(dump + 1);
        uint64_t base = (which >= 0 && which <= 28) ? machine->regs[which] : 0;
        for (int index = 0; index < 12; index++) {
            const uint64_t *word = (const uint64_t *)(uintptr_t)(base + 8 * (uint64_t)index);
            if (!readable(word))
                break;
            fprintf(stderr, "  [x%d+0x%02x] 0x%lx\n", which, index * 8, (unsigned long)*word);
            print_text(*word);
            if (readable((const void *)(uintptr_t)*word)) {
                const uint64_t *inner = (const uint64_t *)(uintptr_t)*word;
                fprintf(stderr, "      => 0x%lx 0x%lx 0x%lx 0x%lx\n", (unsigned long)inner[0], (unsigned long)inner[1],
                        (unsigned long)(readable(inner + 2) ? inner[2] : 0), (unsigned long)(readable(inner + 3) ? inner[3] : 0));
                print_text(inner[0]);
                print_text(inner[1]);
            }
        }
        fflush(stderr);
    }

    // The stack, with what its words point to: what a thread was doing is
    // often written down there.
    if (getenv("MEAD_CRASH_STACK")) {
        const uint64_t *stack = (const uint64_t *)(uintptr_t)machine->sp;
        for (int index = 0; index < 512 && readable(&stack[index]); index++) {
            const mead_image *image = mead_deps_image_for((const void *)(uintptr_t)stack[index]);
            if (image)
                fprintf(stderr, "  %%%d  %s + 0x%lx\n", index, image->path, (unsigned long)(stack[index] - image->load_bias));
            print_text(stack[index]);
        }
        fflush(stderr);
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

// kill -USR2 <pid>, under MEAD_CRASH_REPORT: every thread's name and frames,
// and the game carries on. One write per thread, so that they don't interleave.
static void append_address(char *line, size_t size, size_t *used, uint64_t address) {
    const mead_image *image = mead_deps_image_for((const void *)(uintptr_t)address);
    Dl_info host;
    int added;
    if (image)
        added = snprintf(line + *used, size - *used, " %s+0x%lx", strrchr(image->path, '/') ? strrchr(image->path, '/') + 1 : image->path,
                         (unsigned long)(address - image->load_bias));
    else if (dladdr((const void *)(uintptr_t)address, &host) && host.dli_sname)
        added = snprintf(line + *used, size - *used, " %s", host.dli_sname);
    else
        added = snprintf(line + *used, size - *used, " 0x%lx", (unsigned long)address);
    if (added > 0 && (size_t)added < size - *used)
        *used += (size_t)added;
}

void mead_apply_late_debug_patch(void);

static void on_sample(int number, siginfo_t *information, void *context) {
    if (information->si_code == SI_USER) {
        mead_apply_late_debug_patch();
        DIR *tasks = opendir("/proc/self/task");
        if (tasks) {
            for (struct dirent *entry; (entry = readdir(tasks)) != NULL;) {
                long thread = atol(entry->d_name);
                if (thread > 0 && thread != gettid())
                    syscall(SYS_tgkill, getpid(), thread, number);
            }
            closedir(tasks);
        }
    }
    const mcontext_t *machine = &((const ucontext_t *)context)->uc_mcontext;
    char name[17] = { 0 };
    prctl(PR_GET_NAME, name);
    char line[2048];
    int started = snprintf(line, sizeof(line), "mead: sample %ld %s:", (long)gettid(), name);
    size_t used = started > 0 ? (size_t)started : 0;
    append_address(line, sizeof(line), &used, machine->pc);
    append_address(line, sizeof(line), &used, machine->regs[30]);
    uint64_t frame = machine->regs[29];
    for (int depth = 0; depth < 40 && frame >= 4096 && (frame & 7) == 0 && used < sizeof(line) - 128; depth++) {
        const uint64_t *record = (const uint64_t *)(uintptr_t)frame;
        if (!readable(record))
            break;
        append_address(line, sizeof(line), &used, record[1]);
        if (record[0] <= frame)
            break;
        frame = record[0];
    }
    line[used++] = '\n';
    write(2, line, used);
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
    static const int signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP };
    for (size_t index = 0; index < sizeof(signals) / sizeof(signals[0]); index++)
        sigaction(signals[index], &action, NULL);
    action.sa_sigaction = on_sample;
    action.sa_flags = SA_SIGINFO | SA_RESTART;
    sigaction(SIGUSR2, &action, NULL);
}
