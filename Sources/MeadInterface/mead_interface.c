#define _GNU_SOURCE
#include "mead_interface.h"

#include <dlfcn.h>
#include <execinfo.h>
#include <stdio.h>
#include <unistd.h>

// Prints `title`, then the calling thread's frames by their frame pointers,
// each as the file it is mapped from and the offset in it (for the loader's
// own images, llvm-symbolizer --obj <file> --vmaddr 0), on standard error.
// For tracing who calls a function.
void mead_print_frames(const char *title) {
    fprintf(stderr, "mead: %s\n", title);
    void *frames[64];
    int count = backtrace(frames, sizeof(frames) / sizeof(frames[0]));
    for (int index = 2; index < count; index++) { // this function and its caller
        Dl_info info;
        if (dladdr(frames[index], &info) && info.dli_fname)
            fprintf(stderr, "  %s + 0x%lx\n", info.dli_fname,
                    (unsigned long)((char *)frames[index] - (char *)info.dli_fbase));
        else
            fprintf(stderr, "  %p\n", frames[index]);
    }
}
