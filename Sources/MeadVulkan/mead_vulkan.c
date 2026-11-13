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
#include <time.h>

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

static void remember_surface(VkSurfaceKHR surface, void *window);

static VkResult shim_vkCreateAndroidSurfaceKHR(VkInstance instance, const VkAndroidSurfaceCreateInfoKHR *info,
                                               const void *allocator, VkSurfaceKHR *surface) {
    if (mead_graphics_api() == MEAD_GRAPHICS_VULKAN) {
        typedef void *(*WindowHandle)(void *);
        WindowHandle handle = loader ? (WindowHandle)loader->lookup_symbol(NULL, "mead_android_window_handle") : NULL;
        void *window = handle ? handle(info->window) : NULL;
        if (!window || !ensure_sdl() || !sdl_create_surface(window, instance, allocator, surface))
            return VK_ERROR_INITIALIZATION_FAILED;
        remember_surface(*surface, info->window);
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
        VkResult result = create(instance, &created, allocator, surface);
        if (result == VK_SUCCESS)
            remember_surface(*surface, info->window);
        return result;
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
    VkResult result = create(instance, &created, allocator, surface);
    if (result == VK_SUCCESS)
        remember_surface(*surface, info->window);
    return result;
}

// Android's surfaces always know their size. Wayland's leave it to the
// swapchain, saying so with an extent of all ones, which an Android game
// would take for a very large window. So each surface remembers its window.
typedef struct VkExtent2D {
    uint32_t width, height;
} VkExtent2D;

typedef struct VkSurfaceCapabilitiesKHR {
    uint32_t minImageCount, maxImageCount;
    VkExtent2D currentExtent, minImageExtent, maxImageExtent;
    // the rest is left as the host says
    uint32_t rest[6];
} VkSurfaceCapabilitiesKHR;

enum { MAX_SURFACES = 16 };
static struct {
    VkSurfaceKHR surface;
    void *window;
} surfaces[MAX_SURFACES];
static pthread_mutex_t surfaces_lock = PTHREAD_MUTEX_INITIALIZER;

static void remember_surface(VkSurfaceKHR surface, void *window) {
    pthread_mutex_lock(&surfaces_lock);
    for (int index = 0; index < MAX_SURFACES; index++)
        if (surfaces[index].surface == 0 || surfaces[index].window == window) {
            surfaces[index].surface = surface;
            surfaces[index].window = window;
            break;
        }
    pthread_mutex_unlock(&surfaces_lock);
}

static void *window_of(VkSurfaceKHR surface) {
    void *window = NULL;
    pthread_mutex_lock(&surfaces_lock);
    for (int index = 0; index < MAX_SURFACES && !window; index++)
        if (surfaces[index].surface == surface)
            window = surfaces[index].window;
    pthread_mutex_unlock(&surfaces_lock);
    return window;
}

static uint32_t clamp(uint32_t value, uint32_t low, uint32_t high) {
    return value < low ? low : value > high ? high : value;
}

static void fill_in_extent(VkSurfaceKHR surface, VkSurfaceCapabilitiesKHR *capabilities) {
    if (capabilities->currentExtent.width != UINT32_MAX || !loader)
        return;
    void *window = window_of(surface);
    typedef int32_t (*Measure)(void *);
    Measure width = (Measure)loader->lookup_symbol(NULL, "ANativeWindow_getWidth");
    Measure height = (Measure)loader->lookup_symbol(NULL, "ANativeWindow_getHeight");
    if (!window || !width || !height)
        return;
    capabilities->currentExtent.width = clamp((uint32_t)width(window), capabilities->minImageExtent.width, capabilities->maxImageExtent.width);
    capabilities->currentExtent.height = clamp((uint32_t)height(window), capabilities->minImageExtent.height, capabilities->maxImageExtent.height);
}

static VkResult shim_vkGetPhysicalDeviceSurfaceCapabilitiesKHR(void *device, VkSurfaceKHR surface, VkSurfaceCapabilitiesKHR *capabilities) {
    typedef VkResult (*Get)(void *, VkSurfaceKHR, VkSurfaceCapabilitiesKHR *);
    static Get host;
    if (!host)
        host = (Get)dlsym(vulkan_library, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR");
    VkResult result = host(device, surface, capabilities);
    if (result == VK_SUCCESS)
        fill_in_extent(surface, capabilities);
    return result;
}

// MEAD_VULKAN_FRAME_DUMP=path — writes the image about to be presented to
// `path` as a binary PPM, every 60 presents, as MEAD_FRAME_DUMP does for EGL
// (a separate path, so a window's EGL frames don't overwrite its Vulkan
// ones). A debugging aid for hosts with no way to look at the screen:
// nothing below is shimmed unless the variable is set. Each dumped present
// copies its image to a host buffer after the semaphores it waits on, waits
// for the copy, then presents with nothing left to wait on.
typedef void *VkDevice;
typedef void *VkQueue;
typedef void *VkCommandBuffer;
typedef void *VkPhysicalDevice;
typedef uint64_t VkHandle;

enum {
    VK_STRUCTURE_TYPE_SUBMIT_INFO = 4,
    VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO = 5,
    VK_STRUCTURE_TYPE_FENCE_CREATE_INFO = 8,
    VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO = 12,
    VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO = 39,
    VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO = 40,
    VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO = 42,
    VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER = 45,
    VK_STRUCTURE_TYPE_DEVICE_QUEUE_INFO_2 = 1000145003,
    VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL = 6,
    VK_IMAGE_LAYOUT_PRESENT_SRC_KHR = 1000001002,
    VK_FORMAT_R8G8B8A8_UNORM = 37,
    VK_FORMAT_R8G8B8A8_SRGB = 43,
    VK_FORMAT_B8G8R8A8_UNORM = 44,
    VK_FORMAT_B8G8R8A8_SRGB = 50,
    VK_FORMAT_A2R10G10B10_UNORM_PACK32 = 58,
    VK_FORMAT_A2B10G10R10_UNORM_PACK32 = 64,
};

typedef struct VkSwapchainCreateInfoKHR {
    int32_t sType;
    const void *pNext;
    uint32_t flags;
    VkHandle surface;
    uint32_t minImageCount;
    int32_t imageFormat;
    int32_t imageColorSpace;
    VkExtent2D imageExtent;
    uint32_t imageArrayLayers;
    uint32_t imageUsage;
    // the rest is passed on as the app gave it
} VkSwapchainCreateInfoKHR;

typedef struct VkPresentInfoKHR {
    int32_t sType;
    const void *pNext;
    uint32_t waitSemaphoreCount;
    const VkHandle *pWaitSemaphores;
    uint32_t swapchainCount;
    const VkHandle *pSwapchains;
    const uint32_t *pImageIndices;
    VkResult *pResults;
} VkPresentInfoKHR;

typedef struct VkDeviceQueueInfo2 {
    int32_t sType;
    const void *pNext;
    uint32_t flags;
    uint32_t queueFamilyIndex;
    uint32_t queueIndex;
} VkDeviceQueueInfo2;

typedef struct {
    int32_t sType;
    const void *pNext;
    uint32_t flags;
    uint32_t queueFamilyIndex;
} VkCommandPoolCreateInfo;

typedef struct {
    int32_t sType;
    const void *pNext;
    VkHandle commandPool;
    int32_t level;
    uint32_t commandBufferCount;
} VkCommandBufferAllocateInfo;

typedef struct {
    int32_t sType;
    const void *pNext;
    uint32_t flags;
    const void *pInheritanceInfo;
} VkCommandBufferBeginInfo;

typedef struct {
    int32_t sType;
    const void *pNext;
    uint32_t flags;
    uint64_t size;
    uint32_t usage;
    int32_t sharingMode;
    uint32_t queueFamilyIndexCount;
    const uint32_t *pQueueFamilyIndices;
} VkBufferCreateInfo;

typedef struct {
    uint64_t size, alignment;
    uint32_t memoryTypeBits;
} VkMemoryRequirements;

typedef struct {
    int32_t sType;
    const void *pNext;
    uint64_t allocationSize;
    uint32_t memoryTypeIndex;
} VkMemoryAllocateInfo;

typedef struct {
    uint32_t memoryTypeCount;
    struct {
        uint32_t propertyFlags, heapIndex;
    } memoryTypes[32];
    uint32_t memoryHeapCount;
    struct {
        uint64_t size;
        uint32_t flags;
    } memoryHeaps[16];
} VkPhysicalDeviceMemoryProperties;

typedef struct {
    int32_t sType;
    const void *pNext;
    uint32_t flags;
} VkFenceCreateInfo;

typedef struct {
    int32_t sType;
    const void *pNext;
    uint32_t waitSemaphoreCount;
    const VkHandle *pWaitSemaphores;
    const uint32_t *pWaitDstStageMask;
    uint32_t commandBufferCount;
    const VkCommandBuffer *pCommandBuffers;
    uint32_t signalSemaphoreCount;
    const VkHandle *pSignalSemaphores;
} VkSubmitInfo;

typedef struct {
    int32_t sType;
    const void *pNext;
    uint32_t srcAccessMask, dstAccessMask;
    int32_t oldLayout, newLayout;
    uint32_t srcQueueFamilyIndex, dstQueueFamilyIndex;
    VkHandle image;
    uint32_t aspectMask, baseMipLevel, levelCount, baseArrayLayer, layerCount;
} VkImageMemoryBarrier;

typedef struct {
    uint64_t bufferOffset;
    uint32_t bufferRowLength, bufferImageHeight;
    uint32_t aspectMask, mipLevel, baseArrayLayer, layerCount;
    int32_t x, y, z;
    uint32_t width, height, depth;
} VkBufferImageCopy;

typedef PFN_vkVoidFunction (*PFN_vkGetDeviceProcAddr)(VkDevice, const char *);

static const char *dump_path;
// MEAD_VULKAN_FPS: presents per second, written to standard error each
// second, to compare frame rates across hosts and builds.
static bool counting_frames;
static PFN_vkGetDeviceProcAddr host_get_device_proc_addr;

static void open_dump(void) {
    dump_path = getenv("MEAD_VULKAN_FRAME_DUMP");
    if (dump_path && !*dump_path)
        dump_path = NULL;
    const char *fps = getenv("MEAD_VULKAN_FPS");
    counting_frames = fps && *fps && strcmp(fps, "0") != 0;
}

// Whether presents are watched, to dump frames or count them; without
// either, nothing is shimmed past the window system.
static bool dumping(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, open_dump);
    return dump_path != NULL || counting_frames;
}

// Counts a present and, once a second has passed since the last report,
// writes the rate and the slowest frame's time.
static void count_frame(void) {
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static struct timespec started, previous;
    static unsigned frames;
    static double slowest;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    pthread_mutex_lock(&lock);
    if (started.tv_sec == 0 && started.tv_nsec == 0) {
        started = previous = now;
        pthread_mutex_unlock(&lock);
        return;
    }
    double frame = (double)(now.tv_sec - previous.tv_sec) + (double)(now.tv_nsec - previous.tv_nsec) / 1e9;
    double elapsed = (double)(now.tv_sec - started.tv_sec) + (double)(now.tv_nsec - started.tv_nsec) / 1e9;
    previous = now;
    frames++;
    if (frame > slowest)
        slowest = frame;
    if (elapsed >= 1) {
        fprintf(stderr, "mead: vulkan: %.1f fps, slowest frame %.1f ms\n", frames / elapsed, slowest * 1000);
        started = now;
        frames = 0;
        slowest = 0;
    }
    pthread_mutex_unlock(&lock);
}

// What a dump needs to know of the objects it reads: each device's physical
// device, each queue's device and family, each swapchain's device, format
// and size.
enum { MAX_TRACKED = 16 };
static struct {
    VkDevice device;
    VkPhysicalDevice physical;
} devices[MAX_TRACKED];
static struct {
    VkQueue queue;
    VkDevice device;
    uint32_t family;
} queues[MAX_TRACKED];
static struct {
    VkHandle swapchain;
    VkDevice device;
    int32_t format;
    VkExtent2D extent;
} swapchains[MAX_TRACKED];
static pthread_mutex_t tracked_lock = PTHREAD_MUTEX_INITIALIZER;

#define DEVICE_FUNCTION(device, name, type) __typeof__(type) name = (__typeof__(type))host_get_device_proc_addr(device, #name)

static void write_ppm(const unsigned char *pixels, uint32_t width, uint32_t height, int32_t format) {
    char temporary[4096];
    snprintf(temporary, sizeof(temporary), "%s.part", dump_path);
    FILE *file = fopen(temporary, "wb");
    if (!file)
        return;
    fprintf(file, "P6\n%u %u\n255\n", width, height);
    unsigned char *row = malloc((size_t)width * 3);
    for (uint32_t y = 0; row && y < height; y++) {
        const uint32_t *source = (const uint32_t *)(pixels + (size_t)y * width * 4);
        for (uint32_t x = 0; x < width; x++) {
            uint32_t pixel = source[x];
            unsigned char red, green, blue;
            switch (format) {
            case VK_FORMAT_B8G8R8A8_UNORM:
            case VK_FORMAT_B8G8R8A8_SRGB:
                blue = pixel & 0xff, green = (pixel >> 8) & 0xff, red = (pixel >> 16) & 0xff;
                break;
            case VK_FORMAT_A2R10G10B10_UNORM_PACK32:
                blue = (pixel >> 2) & 0xff, green = (pixel >> 12) & 0xff, red = (pixel >> 22) & 0xff;
                break;
            case VK_FORMAT_A2B10G10R10_UNORM_PACK32:
                red = (pixel >> 2) & 0xff, green = (pixel >> 12) & 0xff, blue = (pixel >> 22) & 0xff;
                break;
            default: // R8G8B8A8
                red = pixel & 0xff, green = (pixel >> 8) & 0xff, blue = (pixel >> 16) & 0xff;
                break;
            }
            row[x * 3] = red, row[x * 3 + 1] = green, row[x * 3 + 2] = blue;
        }
        fwrite(row, 1, (size_t)width * 3, file);
    }
    free(row);
    fclose(file);
    rename(temporary, dump_path);
}

static bool dumpable_format(int32_t format) {
    return format == VK_FORMAT_R8G8B8A8_UNORM || format == VK_FORMAT_R8G8B8A8_SRGB || format == VK_FORMAT_B8G8R8A8_UNORM ||
           format == VK_FORMAT_B8G8R8A8_SRGB || format == VK_FORMAT_A2R10G10B10_UNORM_PACK32 ||
           format == VK_FORMAT_A2B10G10R10_UNORM_PACK32;
}

// Copies the image, after the present's semaphores, and writes it. True
// when the semaphores were waited on, so the present mustn't wait again.
static bool dump_image(VkQueue queue, const VkPresentInfoKHR *info) {
    VkDevice device = NULL, swapchain_device = NULL;
    VkPhysicalDevice physical = NULL;
    uint32_t family = 0;
    int32_t format = 0;
    VkExtent2D extent = { 0, 0 };
    pthread_mutex_lock(&tracked_lock);
    for (int index = 0; index < MAX_TRACKED; index++) {
        if (queues[index].queue == queue && queue)
            device = queues[index].device, family = queues[index].family;
        if (swapchains[index].swapchain == info->pSwapchains[0] && info->pSwapchains[0])
            swapchain_device = swapchains[index].device, format = swapchains[index].format, extent = swapchains[index].extent;
    }
    for (int index = 0; index < MAX_TRACKED; index++)
        if (devices[index].device == device && device)
            physical = devices[index].physical;
    pthread_mutex_unlock(&tracked_lock);
    if (!device || device != swapchain_device || !physical || !dumpable_format(format) || !extent.width || !extent.height)
        return false;

    DEVICE_FUNCTION(device, vkGetSwapchainImagesKHR, VkResult (*)(VkDevice, VkHandle, uint32_t *, VkHandle *));
    DEVICE_FUNCTION(device, vkCreateBuffer, VkResult (*)(VkDevice, const VkBufferCreateInfo *, const void *, VkHandle *));
    DEVICE_FUNCTION(device, vkDestroyBuffer, void (*)(VkDevice, VkHandle, const void *));
    DEVICE_FUNCTION(device, vkGetBufferMemoryRequirements, void (*)(VkDevice, VkHandle, VkMemoryRequirements *));
    DEVICE_FUNCTION(device, vkAllocateMemory, VkResult (*)(VkDevice, const VkMemoryAllocateInfo *, const void *, VkHandle *));
    DEVICE_FUNCTION(device, vkFreeMemory, void (*)(VkDevice, VkHandle, const void *));
    DEVICE_FUNCTION(device, vkBindBufferMemory, VkResult (*)(VkDevice, VkHandle, VkHandle, uint64_t));
    DEVICE_FUNCTION(device, vkMapMemory, VkResult (*)(VkDevice, VkHandle, uint64_t, uint64_t, uint32_t, void **));
    DEVICE_FUNCTION(device, vkUnmapMemory, void (*)(VkDevice, VkHandle));
    DEVICE_FUNCTION(device, vkCreateCommandPool, VkResult (*)(VkDevice, const VkCommandPoolCreateInfo *, const void *, VkHandle *));
    DEVICE_FUNCTION(device, vkDestroyCommandPool, void (*)(VkDevice, VkHandle, const void *));
    DEVICE_FUNCTION(device, vkAllocateCommandBuffers, VkResult (*)(VkDevice, const VkCommandBufferAllocateInfo *, VkCommandBuffer *));
    DEVICE_FUNCTION(device, vkBeginCommandBuffer, VkResult (*)(VkCommandBuffer, const VkCommandBufferBeginInfo *));
    DEVICE_FUNCTION(device, vkEndCommandBuffer, VkResult (*)(VkCommandBuffer));
    DEVICE_FUNCTION(device, vkCmdPipelineBarrier, void (*)(VkCommandBuffer, uint32_t, uint32_t, uint32_t, uint32_t, const void *, uint32_t, const void *, uint32_t, const VkImageMemoryBarrier *));
    DEVICE_FUNCTION(device, vkCmdCopyImageToBuffer, void (*)(VkCommandBuffer, VkHandle, int32_t, VkHandle, uint32_t, const VkBufferImageCopy *));
    DEVICE_FUNCTION(device, vkCreateFence, VkResult (*)(VkDevice, const VkFenceCreateInfo *, const void *, VkHandle *));
    DEVICE_FUNCTION(device, vkDestroyFence, void (*)(VkDevice, VkHandle, const void *));
    DEVICE_FUNCTION(device, vkWaitForFences, VkResult (*)(VkDevice, uint32_t, const VkHandle *, uint32_t, uint64_t));
    DEVICE_FUNCTION(device, vkQueueSubmit, VkResult (*)(VkQueue, uint32_t, const VkSubmitInfo *, VkHandle));
    typedef void (*GetMemoryProperties)(VkPhysicalDevice, VkPhysicalDeviceMemoryProperties *);
    GetMemoryProperties memory_properties = (GetMemoryProperties)dlsym(vulkan_library, "vkGetPhysicalDeviceMemoryProperties");
    if (!vkGetSwapchainImagesKHR || !vkCreateBuffer || !vkAllocateMemory || !vkCreateCommandPool || !vkAllocateCommandBuffers ||
        !vkCmdPipelineBarrier || !vkCmdCopyImageToBuffer || !vkCreateFence || !vkQueueSubmit || !memory_properties)
        return false;

    uint32_t count = 0;
    if (vkGetSwapchainImagesKHR(device, info->pSwapchains[0], &count, NULL) != VK_SUCCESS || info->pImageIndices[0] >= count)
        return false;
    VkHandle *images = calloc(count, sizeof(*images));
    if (!images || vkGetSwapchainImagesKHR(device, info->pSwapchains[0], &count, images) != VK_SUCCESS) {
        free(images);
        return false;
    }
    VkHandle image = images[info->pImageIndices[0]];
    free(images);

    uint64_t size = (uint64_t)extent.width * extent.height * 4;
    VkHandle buffer = 0, memory = 0, pool = 0, fence = 0;
    VkCommandBuffer commands = NULL;
    bool waited = false;
    VkBufferCreateInfo buffer_info = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = 0x2 /* TRANSFER_DST */ };
    if (vkCreateBuffer(device, &buffer_info, NULL, &buffer) != VK_SUCCESS)
        goto done;
    VkMemoryRequirements requirements;
    vkGetBufferMemoryRequirements(device, buffer, &requirements);
    VkPhysicalDeviceMemoryProperties properties;
    memory_properties(physical, &properties);
    uint32_t type = UINT32_MAX;
    for (uint32_t index = 0; index < properties.memoryTypeCount && type == UINT32_MAX; index++)
        if ((requirements.memoryTypeBits & (1u << index)) && (properties.memoryTypes[index].propertyFlags & 0x6) == 0x6)
            type = index; // HOST_VISIBLE | HOST_COHERENT
    VkMemoryAllocateInfo allocate = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = requirements.size, .memoryTypeIndex = type };
    if (type == UINT32_MAX || vkAllocateMemory(device, &allocate, NULL, &memory) != VK_SUCCESS ||
        vkBindBufferMemory(device, buffer, memory, 0) != VK_SUCCESS)
        goto done;
    VkCommandPoolCreateInfo pool_info = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family };
    VkCommandBufferAllocateInfo command_info = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandBufferCount = 1 };
    if (vkCreateCommandPool(device, &pool_info, NULL, &pool) != VK_SUCCESS)
        goto done;
    command_info.commandPool = pool;
    if (vkAllocateCommandBuffers(device, &command_info, &commands) != VK_SUCCESS)
        goto done;
    // As the loader does for the buffers it hands out: the driver's dispatch.
    *(void **)commands = *(void **)device;
    VkCommandBufferBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = 0x1 /* ONE_TIME_SUBMIT */ };
    vkBeginCommandBuffer(commands, &begin);
    VkImageMemoryBarrier barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = 0,
        .dstAccessMask = 0x800, // TRANSFER_READ
        .oldLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = UINT32_MAX,
        .dstQueueFamilyIndex = UINT32_MAX,
        .image = image,
        .aspectMask = 1, // COLOR
        .levelCount = 1,
        .layerCount = 1,
    };
    vkCmdPipelineBarrier(commands, 0x10000 /* ALL_COMMANDS */, 0x1000 /* TRANSFER */, 0, 0, NULL, 0, NULL, 1, &barrier);
    VkBufferImageCopy region = { .aspectMask = 1, .layerCount = 1, .width = extent.width, .height = extent.height, .depth = 1 };
    vkCmdCopyImageToBuffer(commands, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &region);
    barrier.srcAccessMask = 0x800;
    barrier.dstAccessMask = 0;
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    vkCmdPipelineBarrier(commands, 0x1000, 0x2000 /* BOTTOM_OF_PIPE */, 0, 0, NULL, 0, NULL, 1, &barrier);
    vkEndCommandBuffer(commands);

    VkFenceCreateInfo fence_info = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    if (vkCreateFence(device, &fence_info, NULL, &fence) != VK_SUCCESS)
        goto done;
    uint32_t *stages = calloc(info->waitSemaphoreCount ? info->waitSemaphoreCount : 1, sizeof(*stages));
    for (uint32_t index = 0; stages && index < info->waitSemaphoreCount; index++)
        stages[index] = 0x10000;
    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = info->waitSemaphoreCount,
        .pWaitSemaphores = info->pWaitSemaphores,
        .pWaitDstStageMask = stages,
        .commandBufferCount = 1,
        .pCommandBuffers = &commands,
    };
    if (stages && vkQueueSubmit(queue, 1, &submit, fence) == VK_SUCCESS) {
        waited = true;
        void *mapped = NULL;
        if (vkWaitForFences(device, 1, &fence, 1, 5000000000ull) == VK_SUCCESS &&
            vkMapMemory(device, memory, 0, size, 0, &mapped) == VK_SUCCESS) {
            write_ppm(mapped, extent.width, extent.height, format);
            vkUnmapMemory(device, memory);
        }
    }
    free(stages);

done:
    if (fence)
        vkDestroyFence(device, fence, NULL);
    if (pool)
        vkDestroyCommandPool(device, pool, NULL);
    if (buffer)
        vkDestroyBuffer(device, buffer, NULL);
    if (memory)
        vkFreeMemory(device, memory, NULL);
    return waited;
}

static VkResult shim_vkCreateDevice(VkPhysicalDevice physical, const void *info, const void *allocator, VkDevice *device) {
    typedef VkResult (*Create)(VkPhysicalDevice, const void *, const void *, VkDevice *);
    Create host = (Create)dlsym(vulkan_library, "vkCreateDevice");
    VkResult result = host(physical, info, allocator, device);
    if (result == VK_SUCCESS) {
        pthread_mutex_lock(&tracked_lock);
        for (int index = 0; index < MAX_TRACKED; index++)
            if (devices[index].device == NULL || devices[index].device == *device) {
                devices[index].device = *device;
                devices[index].physical = physical;
                break;
            }
        pthread_mutex_unlock(&tracked_lock);
    }
    return result;
}

static void remember_queue(VkDevice device, uint32_t family, VkQueue queue) {
    if (!queue)
        return;
    pthread_mutex_lock(&tracked_lock);
    for (int index = 0; index < MAX_TRACKED; index++)
        if (queues[index].queue == NULL || queues[index].queue == queue) {
            queues[index].queue = queue;
            queues[index].device = device;
            queues[index].family = family;
            break;
        }
    pthread_mutex_unlock(&tracked_lock);
}

static void shim_vkGetDeviceQueue(VkDevice device, uint32_t family, uint32_t index, VkQueue *queue) {
    DEVICE_FUNCTION(device, vkGetDeviceQueue, void (*)(VkDevice, uint32_t, uint32_t, VkQueue *));
    vkGetDeviceQueue(device, family, index, queue);
    remember_queue(device, family, *queue);
}

static void shim_vkGetDeviceQueue2(VkDevice device, const VkDeviceQueueInfo2 *info, VkQueue *queue) {
    DEVICE_FUNCTION(device, vkGetDeviceQueue2, void (*)(VkDevice, const VkDeviceQueueInfo2 *, VkQueue *));
    vkGetDeviceQueue2(device, info, queue);
    remember_queue(device, info->queueFamilyIndex, *queue);
}

// The full VkSwapchainCreateInfoKHR on 64-bit: the fields past imageUsage
// are passed on as the app gave them.
enum { SWAPCHAIN_CREATE_INFO_SIZE = 104 };

static VkResult shim_vkCreateSwapchainKHR(VkDevice device, const VkSwapchainCreateInfoKHR *info, const void *allocator,
                                          VkHandle *swapchain) {
    DEVICE_FUNCTION(device, vkCreateSwapchainKHR, VkResult (*)(VkDevice, const void *, const void *, VkHandle *));
    // Its images are copied from, so they need to allow it; if the host
    // won't, the swapchain is made as asked and not dumped.
    unsigned char copied[SWAPCHAIN_CREATE_INFO_SIZE];
    memcpy(copied, info, sizeof(copied));
    if (dump_path)
        ((VkSwapchainCreateInfoKHR *)copied)->imageUsage |= 0x1; // TRANSFER_SRC
    bool readable = true;
    VkResult result = vkCreateSwapchainKHR(device, copied, allocator, swapchain);
    if (result != VK_SUCCESS) {
        readable = false;
        result = vkCreateSwapchainKHR(device, info, allocator, swapchain);
    }
    if (result == VK_SUCCESS) {
        pthread_mutex_lock(&tracked_lock);
        for (int index = 0; index < MAX_TRACKED; index++)
            if (swapchains[index].swapchain == 0 || swapchains[index].swapchain == *swapchain) {
                swapchains[index].swapchain = *swapchain;
                swapchains[index].device = device;
                swapchains[index].format = readable ? info->imageFormat : 0;
                swapchains[index].extent = info->imageExtent;
                break;
            }
        pthread_mutex_unlock(&tracked_lock);
    }
    return result;
}

static void shim_vkDestroySwapchainKHR(VkDevice device, VkHandle swapchain, const void *allocator) {
    DEVICE_FUNCTION(device, vkDestroySwapchainKHR, void (*)(VkDevice, VkHandle, const void *));
    pthread_mutex_lock(&tracked_lock);
    for (int index = 0; index < MAX_TRACKED; index++)
        if (swapchains[index].swapchain == swapchain && swapchain)
            memset(&swapchains[index], 0, sizeof(swapchains[index]));
    pthread_mutex_unlock(&tracked_lock);
    vkDestroySwapchainKHR(device, swapchain, allocator);
}

static VkResult shim_vkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *info) {
    static unsigned presents;
    VkDevice device = NULL;
    pthread_mutex_lock(&tracked_lock);
    for (int index = 0; index < MAX_TRACKED && !device; index++)
        if (queues[index].queue == queue)
            device = queues[index].device;
    pthread_mutex_unlock(&tracked_lock);
    typedef VkResult (*Present)(VkQueue, const VkPresentInfoKHR *);
    // A queue the dump didn't see made goes through the loader.
    Present vkQueuePresentKHR = device ? (Present)host_get_device_proc_addr(device, "vkQueuePresentKHR")
                                       : (Present)dlsym(vulkan_library, "vkQueuePresentKHR");
    if (counting_frames && info->swapchainCount > 0)
        count_frame();
    if (!device)
        return vkQueuePresentKHR(queue, info);
    if (dump_path && info->swapchainCount > 0 && __atomic_fetch_add(&presents, 1, __ATOMIC_RELAXED) % 60 == 0 && dump_image(queue, info)) {
        VkPresentInfoKHR waited = *info;
        waited.waitSemaphoreCount = 0;
        waited.pWaitSemaphores = NULL;
        return vkQueuePresentKHR(queue, &waited);
    }
    return vkQueuePresentKHR(queue, info);
}

static PFN_vkGetDeviceProcAddr shim_vkGetDeviceProcAddr_for_dump(void);

static void open_device_proc_addr(void) {
    host_get_device_proc_addr = (PFN_vkGetDeviceProcAddr)dlsym(vulkan_library, "vkGetDeviceProcAddr");
}

// Whether frames are dumped, with what the dump needs at hand.
static bool ready_to_dump(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    if (!dumping() || !ensure_library())
        return false;
    pthread_once(&once, open_device_proc_addr);
    return host_get_device_proc_addr != NULL;
}

static PFN_vkVoidFunction dump_shim_for(const char *name) {
    if (!ready_to_dump())
        return NULL;
    if (strcmp(name, "vkGetDeviceProcAddr") == 0)
        return (PFN_vkVoidFunction)shim_vkGetDeviceProcAddr_for_dump();
    if (strcmp(name, "vkCreateDevice") == 0)
        return (PFN_vkVoidFunction)shim_vkCreateDevice;
    if (strcmp(name, "vkGetDeviceQueue") == 0)
        return (PFN_vkVoidFunction)shim_vkGetDeviceQueue;
    if (strcmp(name, "vkGetDeviceQueue2") == 0)
        return (PFN_vkVoidFunction)shim_vkGetDeviceQueue2;
    if (strcmp(name, "vkCreateSwapchainKHR") == 0)
        return (PFN_vkVoidFunction)shim_vkCreateSwapchainKHR;
    if (strcmp(name, "vkDestroySwapchainKHR") == 0)
        return (PFN_vkVoidFunction)shim_vkDestroySwapchainKHR;
    if (strcmp(name, "vkQueuePresentKHR") == 0)
        return (PFN_vkVoidFunction)shim_vkQueuePresentKHR;
    return NULL;
}

// Device functions, for the dump's shims; the rest are the host's.
static PFN_vkVoidFunction shim_vkGetDeviceProcAddr(VkDevice device, const char *name) {
    PFN_vkVoidFunction shim = dump_shim_for(name);
    return shim ? shim : host_get_device_proc_addr(device, name);
}

static PFN_vkGetDeviceProcAddr shim_vkGetDeviceProcAddr_for_dump(void) {
    return shim_vkGetDeviceProcAddr;
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
    if (strcmp(name, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR") == 0)
        return (PFN_vkVoidFunction)shim_vkGetPhysicalDeviceSurfaceCapabilitiesKHR;
    return dump_shim_for(name);
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
