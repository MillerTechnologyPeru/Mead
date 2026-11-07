#ifndef MEAD_INTERFACE_H
#define MEAD_INTERFACE_H

// Interface between the mead loader and the Linux provider libraries that
// stand in for Android's (libMeadBionic.so for libc.so, libMeadAndroid.so
// for libandroid.so, and so on). The loader maps an Android arm64 ELF image
// and binds its imports to the providers; the providers are ordinary Linux
// ELF libraries.

#include <stdbool.h>
#include <stdint.h>

// Swift reads this; #define would not cross into it.
enum { MEAD_STARTUP_INFO_VERSION = 1 };

typedef struct mead_startup_info {
    uint32_t version;
    int argc;
    char **argv;
    char **envp;
    const char *progname;          // the game library the loader was pointed at
    const char *data_dir;          // its directory tree (lib/arm64-v8a, assets)

    // Looks up a symbol by its Android soname ("libc.so") and name
    // ("strlen") in the provider standing in for that soname, loading it if
    // needed, or in the Android images already loaded. A NULL soname
    // searches as dlsym(RTLD_DEFAULT) does: the Android images in load
    // order, then the providers. NULL if missing.
    void *(*lookup_symbol)(const char *soname, const char *name);

    // Loads an Android library the game opens while it runs (dlopen): maps
    // it and what it needs that isn't loaded yet, binds it and runs its
    // initializers, as for the game's own libraries at startup. True if the
    // library is loaded, now or already; false if `path` isn't an Android
    // ELF library.
    bool (*load_library)(const char *path);

    // Looks a symbol up as dlsym(RTLD_NEXT) does for code at `caller`: in
    // the Android images loaded after the one `caller` is in, then in the
    // providers. NULL if missing.
    void *(*lookup_symbol_after)(const void *caller, const char *name);
} mead_startup_info;

// Providers may export this function. The loader calls it after mapping and
// binding every image, before any Android initializer runs.
typedef void (*mead_provider_startup_fn)(const mead_startup_info *info);
#define MEAD_PROVIDER_STARTUP_SYMBOL "mead_provider_startup"

// An Android image as the unwinder and dl_iterate_phdr see it.
typedef struct mead_image_info {
    const char *path;              // as loaded
    const void *base;              // lowest mapped address (the phdr vaddr added)
    const void *phdr;              // program headers in memory
    uint64_t phnum;
    uint64_t phentsize;
} mead_image_info;

// Providers may export this function. The loader calls it for each Android
// image after the images it needs are initialized and just before its own
// initializers run: where the FakeJNI runtime gives the image's JNI_OnLoad
// its JavaVM, and where its registered natives are kept with it.
typedef void (*mead_provider_image_fn)(const mead_image_info *image);
#define MEAD_PROVIDER_IMAGE_INIT_SYMBOL "mead_provider_image_init"

// Providers may export this function. The loader calls it, while binding,
// for a symbol the provider does not define as an ELF symbol; it returns the
// symbol's address, or NULL. Lets a provider define data symbols, such as
// exported constants and errno, at run time. Called before
// mead_provider_startup.
typedef void *(*mead_provider_symbol_fn)(const char *name);
#define MEAD_PROVIDER_SYMBOL_SYMBOL "mead_provider_symbol"

// Prints `title`, then the calling thread's frames by their frame pointers,
// each as the file it is mapped from and the offset in it, on standard
// error. For tracing who calls a function.
void mead_print_frames(const char *title);

#endif
