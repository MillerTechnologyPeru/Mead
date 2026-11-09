// libEGL.so, libGLESv1_CM.so, libGLESv2.so and libGLESv3.so: the host's own,
// whose C ABI is Android's. Only what mentions a native window needs care,
// and the two config attributes that exist only on Android.

#define _GNU_SOURCE
#include "mead_egl.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *EGLDisplay;
typedef void *EGLConfig;
typedef void *EGLSurface;
typedef int32_t EGLint;
typedef uint32_t EGLBoolean;

enum {
    EGL_ALPHA_SIZE = 0x3021,
    EGL_RED_SIZE = 0x3024,
    EGL_NONE = 0x3038,
    EGL_NATIVE_VISUAL_ID = 0x302e,
    EGL_RECORDABLE_ANDROID = 0x3142,
    EGL_FRAMEBUFFER_TARGET_ANDROID = 0x3147,
    WINDOW_FORMAT_RGBA_8888 = 1,
    WINDOW_FORMAT_RGBX_8888 = 2,
    WINDOW_FORMAT_RGB_565 = 4,
};

static void *egl_library, *gles2_library, *gles1_library;

static void open_libraries(void) {
    egl_library = dlopen("libEGL.so.1", RTLD_NOW);
    gles2_library = dlopen("libGLESv2.so.2", RTLD_NOW);
    gles1_library = dlopen("libGLESv1_CM.so.1", RTLD_NOW);
}

static void ensure_libraries(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, open_libraries);
}

// A host EGL function, looked up once.
#define HOST(name, type)                                                                   \
    static __typeof__(type) host;                                                                    \
    if (!host) {                                                                           \
        ensure_libraries();                                                                \
        host = (type)(egl_library ? dlsym(egl_library, name) : NULL);                      \
        if (!host) {                                                                       \
            fprintf(stderr, "mead: the host's libEGL has no %s\n", name);                  \
            abort();                                                                       \
        }                                                                                  \
    }

static const mead_startup_info *loader;

void mead_provider_startup(const mead_startup_info *info) {
    loader = info;
}

static bool native_window(void *window, mead_native_window *out) {
    memset(out, 0, sizeof(*out));
    if (!loader)
        return false;
    mead_android_window_native_fn describe =
        (mead_android_window_native_fn)loader->lookup_symbol(NULL, MEAD_ANDROID_WINDOW_NATIVE_SYMBOL);
    return describe && describe(window, out);
}

// Android has one display. Here it is the windowing connection the app's
// window is on, as an EGL display on anything else could not draw to it.
static EGLDisplay shim_eglGetDisplay(void *display) {
    HOST("eglGetDisplay", EGLDisplay (*)(void *))
    if (mead_graphics_api() == MEAD_GRAPHICS_VULKAN)
        return NULL; // EGL_NO_DISPLAY: Vulkan was chosen, so there is no GLES
    if (display == NULL) {
        mead_native_window native;
        if (native_window(NULL, &native))
            return host(native.display);
    }
    return host(display);
}

static EGLSurface shim_eglCreateWindowSurface(EGLDisplay display, EGLConfig config, void *window,
                                              const EGLint *attributes) {
    HOST("eglCreateWindowSurface", EGLSurface (*)(EGLDisplay, EGLConfig, void *, const EGLint *))
    mead_native_window native;
    if (!native_window(window, &native)) {
        fprintf(stderr, "mead: eglCreateWindowSurface: the window is on no windowing system mead knows\n");
        return NULL;
    }
    void *handle = native.kind == MEAD_NATIVE_WINDOW_X11 ? (void *)native.window : native.egl_window;
    return host(display, config, handle, attributes);
}

// The host refuses attributes it has never heard of; these two only ask for
// things that do not apply here.
static EGLBoolean shim_eglChooseConfig(EGLDisplay display, const EGLint *attributes, EGLConfig *configs,
                                       EGLint size, EGLint *count) {
    HOST("eglChooseConfig", EGLBoolean (*)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *))
    if (!attributes)
        return host(display, attributes, configs, size, count);
    size_t length = 0;
    while (attributes[length] != EGL_NONE)
        length += 2;
    EGLint filtered[length + 1];
    size_t kept = 0;
    for (size_t index = 0; index < length; index += 2) {
        if (attributes[index] == EGL_RECORDABLE_ANDROID || attributes[index] == EGL_FRAMEBUFFER_TARGET_ANDROID)
            continue;
        filtered[kept++] = attributes[index];
        filtered[kept++] = attributes[index + 1];
    }
    filtered[kept] = EGL_NONE;
    return host(display, filtered, configs, size, count);
}

// On Android a config's visual ID is a window format, which games hand to
// ANativeWindow_setBuffersGeometry. The host's is an X visual.
static EGLBoolean shim_eglGetConfigAttrib(EGLDisplay display, EGLConfig config, EGLint attribute, EGLint *value) {
    HOST("eglGetConfigAttrib", EGLBoolean (*)(EGLDisplay, EGLConfig, EGLint, EGLint *))
    if (attribute != EGL_NATIVE_VISUAL_ID)
        return host(display, config, attribute, value);
    EGLint red = 8, alpha = 0;
    host(display, config, EGL_RED_SIZE, &red);
    host(display, config, EGL_ALPHA_SIZE, &alpha);
    *value = red < 8 ? WINDOW_FORMAT_RGB_565 : alpha > 0 ? WINDOW_FORMAT_RGBA_8888 : WINDOW_FORMAT_RGBX_8888;
    return 1;
}

static void *shim_eglGetProcAddress(const char *name);

// MEAD_FRAME_DUMP=path — writes the frame about to be shown to `path` as a
// binary PPM, every 60 swaps. A debugging aid for hosts with no way to look
// at the screen: nothing runs it unless the variable is set.
static void dump_frame(EGLDisplay display, EGLSurface surface) {
    static unsigned swaps;
    const char *path = getenv("MEAD_FRAME_DUMP");
    if (!path || swaps++ % 60 != 0)
        return;
    HOST("eglQuerySurface", EGLBoolean (*)(EGLDisplay, EGLSurface, EGLint, EGLint *))
    EGLint width = 0, height = 0;
    if (!host(display, surface, 0x3057 /* EGL_WIDTH */, &width) || !host(display, surface, 0x3056 /* EGL_HEIGHT */, &height) ||
        width <= 0 || height <= 0)
        return;
    void (*get_integer)(unsigned, int *) = (void (*)(unsigned, int *))dlsym(gles2_library, "glGetIntegerv");
    void (*bind_framebuffer)(unsigned, unsigned) = (void (*)(unsigned, unsigned))dlsym(gles2_library, "glBindFramebuffer");
    void (*read_pixels)(int, int, int, int, unsigned, unsigned, void *) =
        (void (*)(int, int, int, int, unsigned, unsigned, void *))dlsym(gles2_library, "glReadPixels");
    unsigned char *pixels = malloc((size_t)width * (size_t)height * 4);
    FILE *file = fopen(path, "wb");
    if (get_integer && bind_framebuffer && read_pixels && pixels && file) {
        int bound = 0;
        get_integer(0x8CAA /* GL_READ_FRAMEBUFFER_BINDING */, &bound);
        bind_framebuffer(0x8CA8 /* GL_READ_FRAMEBUFFER */, 0);
        read_pixels(0, 0, width, height, 0x1908 /* GL_RGBA */, 0x1401 /* GL_UNSIGNED_BYTE */, pixels);
        bind_framebuffer(0x8CA8, (unsigned)bound);
        fprintf(file, "P6\n%d %d\n255\n", width, height);
        for (EGLint row = height - 1; row >= 0; row--)
            for (EGLint column = 0; column < width; column++)
                fwrite(pixels + ((size_t)row * (size_t)width + (size_t)column) * 4, 1, 3, file);
    }
    if (file)
        fclose(file);
    free(pixels);
}

static EGLBoolean shim_eglSwapBuffers(EGLDisplay display, EGLSurface surface) {
    HOST("eglSwapBuffers", EGLBoolean (*)(EGLDisplay, EGLSurface))
    dump_frame(display, surface);
    return host(display, surface);
}

static void *shim_for(const char *name) {
    if (strcmp(name, "eglGetDisplay") == 0)
        return (void *)shim_eglGetDisplay;
    if (strcmp(name, "eglCreateWindowSurface") == 0)
        return (void *)shim_eglCreateWindowSurface;
    if (strcmp(name, "eglSwapBuffers") == 0)
        return (void *)shim_eglSwapBuffers;
    if (strcmp(name, "eglChooseConfig") == 0)
        return (void *)shim_eglChooseConfig;
    if (strcmp(name, "eglGetConfigAttrib") == 0)
        return (void *)shim_eglGetConfigAttrib;
    if (strcmp(name, "eglGetProcAddress") == 0)
        return (void *)shim_eglGetProcAddress;
    return NULL;
}

static void *shim_eglGetProcAddress(const char *name) {
    HOST("eglGetProcAddress", void *(*)(const char *))
    void *shim = shim_for(name);
    return shim ? shim : host(name);
}

static bool has_prefix(const char *name, const char *prefix, size_t length) {
    return strncmp(name, prefix, length) == 0 && name[length] >= 'A' && name[length] <= 'Z';
}

// Only names shaped like EGL's and GL's are asked of the host: dlsym on a
// library also searches what it depends on, and "glob" is not OpenGL.
void *mead_provider_symbol(const char *name) {
    bool is_egl = has_prefix(name, "egl", 3);
    if (!is_egl && !has_prefix(name, "gl", 2))
        return NULL;
    void *shim = shim_for(name);
    if (shim)
        return shim;
    ensure_libraries();
    if (is_egl)
        return egl_library ? dlsym(egl_library, name) : NULL;
    void *symbol = gles2_library ? dlsym(gles2_library, name) : NULL;
    if (!symbol && gles1_library)
        symbol = dlsym(gles1_library, name);
    return symbol;
}
