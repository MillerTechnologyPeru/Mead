// libvulkan.so: the host's loader and drivers, with the Android window
// system integration swapped for the host's. VK_KHR_android_surface is what
// games ask for, and the platform's real surface extension is what gets
// enabled, so a game never learns the difference.

#define _GNU_SOURCE
#include "mead_vulkan.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int32_t VkResult;
typedef void *VkInstance;
typedef uint64_t VkSurfaceKHR;
typedef void (*PFN_vkVoidFunction)(void);

enum {
    VK_SUCCESS = 0,
    VK_INCOMPLETE = 5,
    VK_ERROR_OUT_OF_HOST_MEMORY = -1,
    VK_ERROR_INITIALIZATION_FAILED = -3,
    VK_ERROR_EXTENSION_NOT_PRESENT = -7,
    VK_ERROR_INCOMPATIBLE_DRIVER = -9,
    VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR = 1000004000,
    VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR = 1000006000,
};

typedef struct VkInstanceCreateInfo {
    int32_t sType;
    const void *pNext;
    uint32_t flags;
    const void *pApplicationInfo;
    uint32_t enabledLayerCount;
    const char *const *ppEnabledLayerNames;
    uint32_t enabledExtensionCount;
    const char *const *ppEnabledExtensionNames;
} VkInstanceCreateInfo;

typedef struct VkExtensionProperties {
    char extensionName[256];
    uint32_t specVersion;
} VkExtensionProperties;

typedef struct VkAndroidSurfaceCreateInfoKHR {
    int32_t sType;
    const void *pNext;
    uint32_t flags;
    void *window;
} VkAndroidSurfaceCreateInfoKHR;

typedef struct VkXlibSurfaceCreateInfoKHR {
    int32_t sType;
    const void *pNext;
    uint32_t flags;
    void *display;
    unsigned long window;
} VkXlibSurfaceCreateInfoKHR;

typedef struct VkWaylandSurfaceCreateInfoKHR {
    int32_t sType;
    const void *pNext;
    uint32_t flags;
    void *display;
    void *surface;
} VkWaylandSurfaceCreateInfoKHR;

typedef PFN_vkVoidFunction (*PFN_vkGetInstanceProcAddr)(VkInstance, const char *);

static const char ANDROID_SURFACE[] = "VK_KHR_android_surface";
static const char XLIB_SURFACE[] = "VK_KHR_xlib_surface";
static const char WAYLAND_SURFACE[] = "VK_KHR_wayland_surface";
static const char XCB_SURFACE[] = "VK_KHR_xcb_surface";

static const mead_startup_info *loader;
static void *vulkan_library;
static PFN_vkGetInstanceProcAddr host_get_instance_proc_addr;

void mead_provider_startup(const mead_startup_info *info) {
    loader = info;
}

static void open_library(void) {
    vulkan_library = dlopen("libvulkan.so.1", RTLD_NOW);
    if (vulkan_library)
        host_get_instance_proc_addr = (PFN_vkGetInstanceProcAddr)dlsym(vulkan_library, "vkGetInstanceProcAddr");
}

static bool ensure_library(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, open_library);
    return host_get_instance_proc_addr != NULL;
}

static bool native_window(void *window, mead_native_window *out) {
    memset(out, 0, sizeof(*out));
    if (!loader)
        return false;
    mead_android_window_native_fn describe =
        (mead_android_window_native_fn)loader->lookup_symbol(NULL, MEAD_ANDROID_WINDOW_NATIVE_SYMBOL);
    return describe && describe(window, out);
}

// SDL, for when the window was made for Vulkan: it knows what its video
// driver's surfaces need, and works on whichever driver is in use.
typedef const char *const *(*SDLGetInstanceExtensions)(uint32_t *);
typedef bool (*SDLCreateSurface)(void *, VkInstance, const void *, VkSurfaceKHR *);

static SDLGetInstanceExtensions sdl_get_instance_extensions;
static SDLCreateSurface sdl_create_surface;

static void open_sdl(void) {
    void *sdl = dlopen("libSDL3.so.0", RTLD_NOW);
    if (!sdl)
        return;
    sdl_get_instance_extensions = (SDLGetInstanceExtensions)dlsym(sdl, "SDL_Vulkan_GetInstanceExtensions");
    sdl_create_surface = (SDLCreateSurface)dlsym(sdl, "SDL_Vulkan_CreateSurface");
}

static bool ensure_sdl(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, open_sdl);
    return sdl_get_instance_extensions && sdl_create_surface;
}

static bool is_host_surface_extension(const char *name) {
    return strcmp(name, XLIB_SURFACE) == 0 || strcmp(name, WAYLAND_SURFACE) == 0 || strcmp(name, XCB_SURFACE) == 0;
}

// What the host offers, with its own window systems replaced by Android's.
static VkResult shim_vkEnumerateInstanceExtensionProperties(const char *layer, uint32_t *count,
                                                            VkExtensionProperties *properties) {
    typedef VkResult (*Enumerate)(const char *, uint32_t *, VkExtensionProperties *);
    Enumerate host = (Enumerate)host_get_instance_proc_addr(NULL, "vkEnumerateInstanceExtensionProperties");
    if (layer)
        return host(layer, count, properties);

    uint32_t available = 0;
    VkResult result = host(NULL, &available, NULL);
    if (result != VK_SUCCESS)
        return result;
    VkExtensionProperties *all = calloc(available ? available : 1, sizeof(*all));
    if (!all)
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    result = host(NULL, &available, all);
    if (result != VK_SUCCESS && result != VK_INCOMPLETE) {
        free(all);
        return result;
    }

    uint32_t kept = 0;
    bool any_surface = false;
    for (uint32_t index = 0; index < available; index++) {
        if (is_host_surface_extension(all[index].extensionName))
            any_surface = true;
        else
            all[kept++] = all[index];
    }
    uint32_t total = kept + (any_surface ? 1 : 0);
    if (!properties) {
        *count = total;
        free(all);
        return VK_SUCCESS;
    }

    uint32_t copied = kept < *count ? kept : *count;
    memcpy(properties, all, copied * sizeof(*all));
    if (any_surface && copied < *count && kept == copied) {
        memset(&properties[copied], 0, sizeof(*properties));
        strcpy(properties[copied].extensionName, ANDROID_SURFACE);
        properties[copied].specVersion = 6;
        copied++;
    }
    *count = copied;
    free(all);
    return copied < total ? VK_INCOMPLETE : VK_SUCCESS;
}

static VkResult shim_vkCreateInstance(const VkInstanceCreateInfo *info, const void *allocator, VkInstance *instance) {
    typedef VkResult (*Create)(const VkInstanceCreateInfo *, const void *, VkInstance *);
    Create host = (Create)host_get_instance_proc_addr(NULL, "vkCreateInstance");

    int api = mead_graphics_api();
    if (api == MEAD_GRAPHICS_GLES)
        return VK_ERROR_INCOMPATIBLE_DRIVER; // as on a device with no Vulkan

    uint32_t sdl_count = 0;
    const char *const *sdl_names = NULL;
    if (api == MEAD_GRAPHICS_VULKAN) {
        if (!ensure_sdl() || !(sdl_names = sdl_get_instance_extensions(&sdl_count)))
            return VK_ERROR_INITIALIZATION_FAILED;
    }

    mead_native_window native;
    native_window(NULL, &native);
    uint32_t count = info->enabledExtensionCount;
    const char **names = calloc(count + sdl_count + 1, sizeof(*names));
    if (!names)
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    uint32_t kept = 0;
    for (uint32_t index = 0; index < count; index++) {
        const char *name = info->ppEnabledExtensionNames[index];
        if (strcmp(name, ANDROID_SURFACE) == 0) {
            if (sdl_names)
                continue; // SDL's list, below, has what this stands for
            if (native.kind == MEAD_NATIVE_WINDOW_NONE) {
                free(names);
                return VK_ERROR_EXTENSION_NOT_PRESENT;
            }
            name = native.kind == MEAD_NATIVE_WINDOW_X11 ? XLIB_SURFACE : WAYLAND_SURFACE;
        }
        names[kept++] = name;
    }
    for (uint32_t index = 0; index < sdl_count; index++) {
        bool present = false;
        for (uint32_t other = 0; other < kept && !present; other++)
            present = strcmp(names[other], sdl_names[index]) == 0;
        if (!present)
            names[kept++] = sdl_names[index];
    }
    VkInstanceCreateInfo changed = *info;
    changed.enabledExtensionCount = kept;
    changed.ppEnabledExtensionNames = names;
    VkResult result = host(&changed, allocator, instance);
    free(names);
    return result;
}

static VkResult shim_vkCreateAndroidSurfaceKHR(VkInstance instance, const VkAndroidSurfaceCreateInfoKHR *info,
                                               const void *allocator, VkSurfaceKHR *surface) {
    if (mead_graphics_api() == MEAD_GRAPHICS_VULKAN) {
        typedef void *(*WindowHandle)(void *);
        WindowHandle handle = loader ? (WindowHandle)loader->lookup_symbol(NULL, "mead_android_window_handle") : NULL;
        void *window = handle ? handle(info->window) : NULL;
        if (!window || !ensure_sdl() || !sdl_create_surface(window, instance, allocator, surface))
            return VK_ERROR_INITIALIZATION_FAILED;
        return VK_SUCCESS;
    }
    mead_native_window native;
    if (!native_window(info->window, &native))
        return VK_ERROR_INITIALIZATION_FAILED;
    if (native.kind == MEAD_NATIVE_WINDOW_X11) {
        typedef VkResult (*Create)(VkInstance, const VkXlibSurfaceCreateInfoKHR *, const void *, VkSurfaceKHR *);
        Create create = (Create)host_get_instance_proc_addr(instance, "vkCreateXlibSurfaceKHR");
        if (!create)
            return VK_ERROR_EXTENSION_NOT_PRESENT;
        VkXlibSurfaceCreateInfoKHR created = {
            .sType = VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR,
            .display = native.display,
            .window = (unsigned long)native.window,
        };
        return create(instance, &created, allocator, surface);
    }
    typedef VkResult (*Create)(VkInstance, const VkWaylandSurfaceCreateInfoKHR *, const void *, VkSurfaceKHR *);
    Create create = (Create)host_get_instance_proc_addr(instance, "vkCreateWaylandSurfaceKHR");
    if (!create)
        return VK_ERROR_EXTENSION_NOT_PRESENT;
    VkWaylandSurfaceCreateInfoKHR created = {
        .sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
        .display = native.display,
        .surface = (void *)native.window,
    };
    return create(instance, &created, allocator, surface);
}

static PFN_vkVoidFunction shim_vkGetInstanceProcAddr(VkInstance instance, const char *name);

static PFN_vkVoidFunction shim_for(const char *name) {
    if (strcmp(name, "vkGetInstanceProcAddr") == 0)
        return (PFN_vkVoidFunction)shim_vkGetInstanceProcAddr;
    if (strcmp(name, "vkCreateInstance") == 0)
        return (PFN_vkVoidFunction)shim_vkCreateInstance;
    if (strcmp(name, "vkEnumerateInstanceExtensionProperties") == 0)
        return (PFN_vkVoidFunction)shim_vkEnumerateInstanceExtensionProperties;
    if (strcmp(name, "vkCreateAndroidSurfaceKHR") == 0)
        return (PFN_vkVoidFunction)shim_vkCreateAndroidSurfaceKHR;
    return NULL;
}

static PFN_vkVoidFunction shim_vkGetInstanceProcAddr(VkInstance instance, const char *name) {
    PFN_vkVoidFunction shim = shim_for(name);
    return shim ? shim : host_get_instance_proc_addr(instance, name);
}

// Only names shaped like Vulkan's are asked of the host; see mead_egl.c.
void *mead_provider_symbol(const char *name) {
    if (strncmp(name, "vk", 2) != 0 || name[2] < 'A' || name[2] > 'Z' || !ensure_library())
        return NULL;
    PFN_vkVoidFunction shim = shim_for(name);
    return shim ? (void *)shim : dlsym(vulkan_library, name);
}
