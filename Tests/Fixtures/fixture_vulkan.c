// A real Vulkan app on native_app_glue, loading Vulkan by dlopen: an Android
// surface on its window, a swapchain, one image cleared, its pixels read
// back, and presented. Only success gets as far as finishing.

#define VK_USE_PLATFORM_ANDROID_KHR
#define VK_NO_PROTOTYPES
#include <android/log.h>
#include <android/native_window.h>
#include <android_native_app_glue.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#define CHECK(condition)                                                                   \
    do {                                                                                   \
        if (!(condition)) {                                                                \
            fprintf(stderr, "fixture_vulkan: line %d: %s\n", __LINE__, #condition);        \
            _exit(2);                                                                      \
        }                                                                                  \
    } while (0)
#define VK(call)                                                                           \
    do {                                                                                   \
        VkResult result_ = (call);                                                         \
        if (result_ != VK_SUCCESS) {                                                       \
            fprintf(stderr, "fixture_vulkan: line %d: %s: %d\n", __LINE__, #call, result_); \
            _exit(2);                                                                      \
        }                                                                                  \
    } while (0)

static PFN_vkGetInstanceProcAddr get_instance_proc;

#define INSTANCE_FUNCTION(name) PFN_##name name = (PFN_##name)get_instance_proc(instance, #name); CHECK(name != NULL)
#define GLOBAL_FUNCTION(name) PFN_##name name = (PFN_##name)get_instance_proc(NULL, #name); CHECK(name != NULL)
#define DEVICE_FUNCTION(name) PFN_##name name = (PFN_##name)vkGetDeviceProcAddr(device, #name); CHECK(name != NULL)

static bool drawn;

static uint32_t memory_type(VkPhysicalDeviceMemoryProperties *properties, uint32_t bits, VkMemoryPropertyFlags flags) {
    for (uint32_t index = 0; index < properties->memoryTypeCount; index++)
        if ((bits & (1u << index)) && (properties->memoryTypes[index].propertyFlags & flags) == flags)
            return index;
    CHECK(!"no suitable memory type");
    return 0;
}

static void transition(PFN_vkCmdPipelineBarrier barrier_function, VkCommandBuffer commands, VkImage image,
                       VkImageLayout from, VkImageLayout to, VkAccessFlags source, VkAccessFlags destination) {
    VkImageMemoryBarrier barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = source,
        .dstAccessMask = destination,
        .oldLayout = from,
        .newLayout = to,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
    };
    barrier_function(commands, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
}

static void render(struct android_app *app) {
    void *library = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    CHECK(library != NULL);
    get_instance_proc = (PFN_vkGetInstanceProcAddr)dlsym(library, "vkGetInstanceProcAddr");
    CHECK(get_instance_proc != NULL);
    GLOBAL_FUNCTION(vkEnumerateInstanceExtensionProperties);
    GLOBAL_FUNCTION(vkCreateInstance);

    // Android's window system is on offer, and the host's are not.
    uint32_t count = 0;
    VK(vkEnumerateInstanceExtensionProperties(NULL, &count, NULL));
    CHECK(count > 0);
    VkExtensionProperties *extensions = calloc(count, sizeof(*extensions));
    VK(vkEnumerateInstanceExtensionProperties(NULL, &count, extensions));
    bool android = false, surface_extension = false;
    for (uint32_t index = 0; index < count; index++) {
        android = android || strcmp(extensions[index].extensionName, VK_KHR_ANDROID_SURFACE_EXTENSION_NAME) == 0;
        surface_extension = surface_extension || strcmp(extensions[index].extensionName, VK_KHR_SURFACE_EXTENSION_NAME) == 0;
        CHECK(strcmp(extensions[index].extensionName, "VK_KHR_xlib_surface") != 0);
        CHECK(strcmp(extensions[index].extensionName, "VK_KHR_wayland_surface") != 0);
    }
    CHECK(android && surface_extension);
    uint32_t too_few = 1;
    VkExtensionProperties one;
    CHECK(count > 1 && vkEnumerateInstanceExtensionProperties(NULL, &too_few, &one) == VK_INCOMPLETE);

    const char *instance_extensions[] = { VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_ANDROID_SURFACE_EXTENSION_NAME };
    VkApplicationInfo application = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1 };
    VkInstanceCreateInfo instance_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &application,
        .enabledExtensionCount = 2,
        .ppEnabledExtensionNames = instance_extensions,
    };
    VkInstance instance;
    VK(vkCreateInstance(&instance_info, NULL, &instance));

    INSTANCE_FUNCTION(vkCreateAndroidSurfaceKHR);
    INSTANCE_FUNCTION(vkEnumeratePhysicalDevices);
    INSTANCE_FUNCTION(vkGetPhysicalDeviceProperties);
    INSTANCE_FUNCTION(vkGetPhysicalDeviceQueueFamilyProperties);
    INSTANCE_FUNCTION(vkGetPhysicalDeviceSurfaceSupportKHR);
    INSTANCE_FUNCTION(vkGetPhysicalDeviceSurfaceCapabilitiesKHR);
    INSTANCE_FUNCTION(vkGetPhysicalDeviceSurfaceFormatsKHR);
    INSTANCE_FUNCTION(vkGetPhysicalDeviceMemoryProperties);
    INSTANCE_FUNCTION(vkCreateDevice);
    INSTANCE_FUNCTION(vkGetDeviceProcAddr);
    INSTANCE_FUNCTION(vkDestroySurfaceKHR);
    INSTANCE_FUNCTION(vkDestroyInstance);

    VkAndroidSurfaceCreateInfoKHR surface_info = {
        .sType = VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR,
        .window = app->window,
    };
    VkSurfaceKHR surface;
    VK(vkCreateAndroidSurfaceKHR(instance, &surface_info, NULL, &surface));

    uint32_t device_count = 1;
    VkPhysicalDevice physical;
    VkResult enumerated = vkEnumeratePhysicalDevices(instance, &device_count, &physical);
    CHECK((enumerated == VK_SUCCESS || enumerated == VK_INCOMPLETE) && device_count == 1);
    VkPhysicalDeviceProperties properties;
    vkGetPhysicalDeviceProperties(physical, &properties);
    __android_log_print(ANDROID_LOG_INFO, "fixture_vulkan", "on %s", properties.deviceName);

    uint32_t family_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, NULL);
    VkQueueFamilyProperties *families = calloc(family_count, sizeof(*families));
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, families);
    uint32_t family = UINT32_MAX;
    for (uint32_t index = 0; index < family_count && family == UINT32_MAX; index++) {
        VkBool32 present = VK_FALSE;
        VK(vkGetPhysicalDeviceSurfaceSupportKHR(physical, index, surface, &present));
        if (present && (families[index].queueFlags & VK_QUEUE_GRAPHICS_BIT))
            family = index;
    }
    CHECK(family != UINT32_MAX);

    const float priority = 1.0f;
    VkDeviceQueueCreateInfo queue_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    const char *device_extensions[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };
    VkDeviceCreateInfo device_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledExtensionCount = 1,
        .ppEnabledExtensionNames = device_extensions,
    };
    VkDevice device;
    VK(vkCreateDevice(physical, &device_info, NULL, &device));
    DEVICE_FUNCTION(vkGetDeviceQueue);
    DEVICE_FUNCTION(vkCreateSwapchainKHR);
    DEVICE_FUNCTION(vkGetSwapchainImagesKHR);
    DEVICE_FUNCTION(vkAcquireNextImageKHR);
    DEVICE_FUNCTION(vkQueuePresentKHR);
    DEVICE_FUNCTION(vkCreateCommandPool);
    DEVICE_FUNCTION(vkAllocateCommandBuffers);
    DEVICE_FUNCTION(vkBeginCommandBuffer);
    DEVICE_FUNCTION(vkEndCommandBuffer);
    DEVICE_FUNCTION(vkCmdPipelineBarrier);
    DEVICE_FUNCTION(vkCmdClearColorImage);
    DEVICE_FUNCTION(vkCmdCopyImageToBuffer);
    DEVICE_FUNCTION(vkCreateBuffer);
    DEVICE_FUNCTION(vkGetBufferMemoryRequirements);
    DEVICE_FUNCTION(vkAllocateMemory);
    DEVICE_FUNCTION(vkBindBufferMemory);
    DEVICE_FUNCTION(vkMapMemory);
    DEVICE_FUNCTION(vkCreateSemaphore);
    DEVICE_FUNCTION(vkCreateFence);
    DEVICE_FUNCTION(vkWaitForFences);
    DEVICE_FUNCTION(vkQueueSubmit);
    DEVICE_FUNCTION(vkDeviceWaitIdle);
    DEVICE_FUNCTION(vkDestroyDevice);
    DEVICE_FUNCTION(vkDestroySwapchainKHR);
    DEVICE_FUNCTION(vkDestroyCommandPool);
    DEVICE_FUNCTION(vkDestroyBuffer);
    DEVICE_FUNCTION(vkFreeMemory);
    DEVICE_FUNCTION(vkDestroySemaphore);
    DEVICE_FUNCTION(vkDestroyFence);
    VkQueue queue;
    vkGetDeviceQueue(device, family, 0, &queue);

    VkSurfaceCapabilitiesKHR capabilities;
    VK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, surface, &capabilities));
    CHECK(capabilities.currentExtent.width == (uint32_t)ANativeWindow_getWidth(app->window));
    CHECK(capabilities.currentExtent.height == (uint32_t)ANativeWindow_getHeight(app->window));
    CHECK(capabilities.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_SRC_BIT);
    CHECK(capabilities.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT);

    uint32_t format_count = 1;
    VkSurfaceFormatKHR format;
    VkResult formats = vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &format_count, &format);
    CHECK(formats == VK_SUCCESS || formats == VK_INCOMPLETE);
    CHECK(format.format == VK_FORMAT_B8G8R8A8_UNORM || format.format == VK_FORMAT_B8G8R8A8_SRGB ||
          format.format == VK_FORMAT_R8G8B8A8_UNORM || format.format == VK_FORMAT_R8G8B8A8_SRGB);
    bool swapped = format.format == VK_FORMAT_B8G8R8A8_UNORM || format.format == VK_FORMAT_B8G8R8A8_SRGB;

    VkCompositeAlphaFlagBitsKHR alpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    if (!(capabilities.supportedCompositeAlpha & alpha))
        alpha = VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
    VkSwapchainCreateInfoKHR swapchain_info = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = surface,
        .minImageCount = capabilities.minImageCount,
        .imageFormat = format.format,
        .imageColorSpace = format.colorSpace,
        .imageExtent = capabilities.currentExtent,
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = capabilities.currentTransform,
        .compositeAlpha = alpha,
        .presentMode = VK_PRESENT_MODE_FIFO_KHR,
        .clipped = VK_TRUE,
    };
    VkSwapchainKHR swapchain;
    VK(vkCreateSwapchainKHR(device, &swapchain_info, NULL, &swapchain));

    uint32_t image_count = 0;
    VK(vkGetSwapchainImagesKHR(device, swapchain, &image_count, NULL));
    VkImage *images = calloc(image_count, sizeof(*images));
    VK(vkGetSwapchainImagesKHR(device, swapchain, &image_count, images));

    VkSemaphoreCreateInfo semaphore_info = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    VkSemaphore acquired, finished;
    VK(vkCreateSemaphore(device, &semaphore_info, NULL, &acquired));
    VK(vkCreateSemaphore(device, &semaphore_info, NULL, &finished));
    VkFenceCreateInfo fence_info = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence;
    VK(vkCreateFence(device, &fence_info, NULL, &fence));

    uint32_t width = capabilities.currentExtent.width, height = capabilities.currentExtent.height;
    VkBufferCreateInfo buffer_info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = width * height * 4,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
    };
    VkBuffer buffer;
    VK(vkCreateBuffer(device, &buffer_info, NULL, &buffer));
    VkMemoryRequirements requirements;
    vkGetBufferMemoryRequirements(device, buffer, &requirements);
    VkPhysicalDeviceMemoryProperties memory_properties;
    vkGetPhysicalDeviceMemoryProperties(physical, &memory_properties);
    VkMemoryAllocateInfo allocation = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size,
        .memoryTypeIndex = memory_type(&memory_properties, requirements.memoryTypeBits,
                                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
    };
    VkDeviceMemory memory;
    VK(vkAllocateMemory(device, &allocation, NULL, &memory));
    VK(vkBindBufferMemory(device, buffer, memory, 0));

    VkCommandPoolCreateInfo pool_info = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family };
    VkCommandPool pool;
    VK(vkCreateCommandPool(device, &pool_info, NULL, &pool));
    VkCommandBufferAllocateInfo command_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VkCommandBuffer commands;
    VK(vkAllocateCommandBuffers(device, &command_info, &commands));

    uint32_t index = 0;
    VkResult acquire = vkAcquireNextImageKHR(device, swapchain, UINT64_MAX, acquired, VK_NULL_HANDLE, &index);
    CHECK(acquire == VK_SUCCESS || acquire == VK_SUBOPTIMAL_KHR);

    VkCommandBufferBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    VK(vkBeginCommandBuffer(commands, &begin));
    transition(vkCmdPipelineBarrier, commands, images[index], VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, VK_ACCESS_TRANSFER_WRITE_BIT);
    VkClearColorValue color = { .float32 = { 0.0f, 1.0f, 0.0f, 1.0f } };
    VkImageSubresourceRange range = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
    vkCmdClearColorImage(commands, images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &range);
    transition(vkCmdPipelineBarrier, commands, images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT);
    VkBufferImageCopy copy = {
        .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
        .imageExtent = { width, height, 1 },
    };
    vkCmdCopyImageToBuffer(commands, images[index], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1, &copy);
    transition(vkCmdPipelineBarrier, commands, images[index], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_ACCESS_TRANSFER_READ_BIT, 0);
    VK(vkEndCommandBuffer(commands));

    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &acquired,
        .pWaitDstStageMask = &wait_stage,
        .commandBufferCount = 1,
        .pCommandBuffers = &commands,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &finished,
    };
    VK(vkQueueSubmit(queue, 1, &submit, fence));
    VK(vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_MAX));

    void *mapped = NULL;
    VK(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapped));
    const uint8_t *pixel = (const uint8_t *)mapped + (height / 2 * width + width / 2) * 4;
    uint8_t red = pixel[swapped ? 2 : 0], green = pixel[1], blue = pixel[swapped ? 0 : 2];
    CHECK(red == 0 && green == 255 && blue == 0);

    VkPresentInfoKHR present = {
        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &finished,
        .swapchainCount = 1,
        .pSwapchains = &swapchain,
        .pImageIndices = &index,
    };
    VkResult presented = vkQueuePresentKHR(queue, &present);
    CHECK(presented == VK_SUCCESS || presented == VK_SUBOPTIMAL_KHR);

    VK(vkDeviceWaitIdle(device));
    vkDestroyCommandPool(device, pool, NULL);
    vkDestroyBuffer(device, buffer, NULL);
    vkFreeMemory(device, memory, NULL);
    vkDestroyFence(device, fence, NULL);
    vkDestroySemaphore(device, acquired, NULL);
    vkDestroySemaphore(device, finished, NULL);
    vkDestroySwapchainKHR(device, swapchain, NULL);
    vkDestroyDevice(device, NULL);
    vkDestroySurfaceKHR(instance, surface, NULL);
    vkDestroyInstance(instance, NULL);

    drawn = true;
    __android_log_print(ANDROID_LOG_INFO, "fixture_vulkan", "the swapchain image's pixels are right");
    ANativeActivity_finish(app->activity);
}

static void on_command(struct android_app *app, int32_t command) {
    if (command == APP_CMD_INIT_WINDOW)
        render(app);
}

void android_main(struct android_app *app) {
    app->onAppCmd = on_command;
    while (!app->destroyRequested) {
        struct android_poll_source *source = NULL;
        int ident = ALooper_pollOnce(-1, NULL, NULL, (void **)&source);
        if (ident >= 0 && source != NULL)
            source->process(app, source);
    }
    CHECK(drawn);
}
