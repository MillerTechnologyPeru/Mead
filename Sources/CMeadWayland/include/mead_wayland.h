#ifndef MEAD_WAYLAND_H
#define MEAD_WAYLAND_H

// Wayland for ART's display bridge (Sources/MeadRuntime): libwayland-client,
// libwayland-egl and the protocols' glue that wayland-scanner generated
// (Scripts/generate-wayland-protocols.sh).

#include <sys/syscall.h>
#include <unistd.h>

#include <wayland-client.h>
#include <wayland-egl.h>

#include "xdg-shell-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "xdg-decoration-unstable-v1-client-protocol.h"

// The interfaces registry binds take, by address: Swift sees libwayland's
// interface tables as constants and can't take theirs.
#define MEAD_WAYLAND_INTERFACE(name) \
    static inline const struct wl_interface *mead_##name##_interface(void) { return &name##_interface; }
MEAD_WAYLAND_INTERFACE(wl_compositor)
MEAD_WAYLAND_INTERFACE(wl_subcompositor)
MEAD_WAYLAND_INTERFACE(wl_shm)
MEAD_WAYLAND_INTERFACE(wl_seat)
MEAD_WAYLAND_INTERFACE(wl_output)
MEAD_WAYLAND_INTERFACE(xdg_wm_base)
MEAD_WAYLAND_INTERFACE(wp_viewporter)
MEAD_WAYLAND_INTERFACE(zxdg_decoration_manager_v1)
#undef MEAD_WAYLAND_INTERFACE

// A memfd for shm buffers: glibc declares memfd_create only with
// _GNU_SOURCE, which Swift's Glibc doesn't have.
static inline int mead_wayland_memfd(const char *name) {
    return (int)syscall(SYS_memfd_create, name, 0);
}

#endif
