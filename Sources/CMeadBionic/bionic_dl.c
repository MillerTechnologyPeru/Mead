#include "bionic_internal.h"

#include <stddef.h>

// libdl.so: the loader's, once it has said where it is. Imports bind before
// the providers start, but nothing calls one until initializers run, after.

void *bionic_dlopen(const char *name, int flags) {
    return bionic_loader->dl_open(name, flags);
}

void *bionic_android_dlopen_ext(const char *name, int flags, const void *info) {
    (void)info;
    return bionic_loader->dl_open(name, flags);
}

__attribute__((noinline)) void *bionic_dlsym(void *handle, const char *name) {
    return bionic_loader->dl_sym(handle, name, __builtin_return_address(0));
}

int bionic_dlclose(void *handle) {
    return bionic_loader->dl_close(handle);
}

const char *bionic_dlerror(void) {
    return bionic_loader->dl_error();
}

int bionic_dladdr(const void *address, mead_dl_info *info) {
    return bionic_loader->dl_addr(address, info);
}

int bionic_dl_iterate_phdr(int (*callback)(mead_dl_phdr_info *, size_t, void *), void *data) {
    return bionic_loader->dl_iterate_phdr(callback, data);
}

// Clang's control-flow integrity, for a call its inline check can't decide:
// bionic's libdl looks the target up in the CFI shadow its linker keeps, and
// a target in a module without CFI information is let through. Mead's loader
// keeps no shadow, so no module has that information, and every such call
// goes ahead.
void bionic___cfi_slowpath(uint64_t call_site_type_id, void *target) {
    (void)call_site_type_id, (void)target;
}

void bionic___cfi_slowpath_diag(uint64_t call_site_type_id, void *target, void *diagnostic) {
    (void)call_site_type_id, (void)target, (void)diagnostic;
}
