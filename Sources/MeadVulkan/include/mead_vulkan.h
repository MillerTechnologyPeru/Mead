#ifndef MEAD_VULKAN_H
#define MEAD_VULKAN_H

// libMeadVulkan.so's provider entry points, as mead_interface.h describes them.

#include "mead_interface.h"

void mead_provider_startup(const mead_startup_info *info);
void *mead_provider_symbol(const char *name);

#endif
