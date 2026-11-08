#ifndef MEAD_DL_H
#define MEAD_DL_H

// The dynamic linker as Android code sees it: dlopen and its family over the
// loaded images, for the bionic provider to export. Android's RTLD_DEFAULT
// and RTLD_NEXT are 0 and -1 on arm64, as glibc's are.

#include "mead_interface.h"

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// A NULL name is the process as a whole. A name with a slash is a path; a
// bare one is what is already loaded, a file beside the game's libraries,
// or a provider, as DT_NEEDED finds them. NULL, with mead_dlerror saying
// why, if nothing answers.
void *mead_dlopen(const char *name, int flags);

// `caller` is only read for RTLD_NEXT.
void *mead_dlsym(void *handle, const char *name, const void *caller);

// Always 0: images live as long as the process.
int mead_dlclose(void *handle);

// This thread's last error, once, and then NULL.
const char *mead_dlerror(void);

// The image and nearest exported symbol at an address; the host's answer
// for an address in no image. 0 if neither knows it.
int mead_dladdr(const void *address, mead_dl_info *info);

// Every Android image, then every host library, so an unwinder can cross
// from one to the other. Stops at the first nonzero return.
int mead_dl_iterate_phdr(int (*callback)(mead_dl_phdr_info *, size_t, void *), void *data);

#ifdef __cplusplus
}
#endif

#endif
