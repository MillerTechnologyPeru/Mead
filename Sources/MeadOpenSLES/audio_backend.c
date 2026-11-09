#define _GNU_SOURCE
#include "audio_backend.h"
#include "mead_opensles.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>

static const mead_startup_info *loader;
static audio_api api;
static bool api_ready;

void mead_provider_startup(const mead_startup_info *info) {
    loader = info;
}

void audio_prepare_thread(void) {
    static __thread bool prepared;
    if (prepared)
        return;
    prepared = true;
    if (loader)
        loader->thread_setup();
}

static void load(void) {
    void *sdl = dlopen("libSDL3.so.0", RTLD_NOW);
    if (!sdl) {
        fprintf(stderr, "mead: SDL3 (libSDL3.so.0) could not be loaded for audio\n");
        return;
    }
    bool (*init)(uint32_t) = (bool (*)(uint32_t))dlsym(sdl, "SDL_InitSubSystem");
#define BIND(field, name)                                                                  \
    *(void **)&api.field = dlsym(sdl, name);                                               \
    if (!api.field)                                                                        \
        return;
    BIND(open, "SDL_OpenAudioDeviceStream")
    BIND(resume, "SDL_ResumeAudioStreamDevice")
    BIND(pause, "SDL_PauseAudioStreamDevice")
    BIND(destroy, "SDL_DestroyAudioStream")
    BIND(put, "SDL_PutAudioStreamData")
    BIND(get, "SDL_GetAudioStreamData")
    BIND(queued, "SDL_GetAudioStreamQueued")
    BIND(available, "SDL_GetAudioStreamAvailable")
    BIND(clear, "SDL_ClearAudioStream")
    BIND(set_gain, "SDL_SetAudioStreamGain")
    BIND(error, "SDL_GetError")
    if (!init || !init(MEAD_SDL_INIT_AUDIO)) {
        fprintf(stderr, "mead: SDL audio: %s\n", api.error());
        return;
    }
    api_ready = true;
}

const audio_api *audio_backend(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, load);
    return api_ready ? &api : NULL;
}
