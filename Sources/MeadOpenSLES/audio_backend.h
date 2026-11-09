#ifndef MEAD_AUDIO_BACKEND_H
#define MEAD_AUDIO_BACKEND_H

// SDL3's audio, for OpenSL ES and AAudio to share.

#include "mead_sdl.h"

#include <stdbool.h>

typedef void (*audio_stream_callback)(void *user, void *stream, int additional, int total);

typedef struct audio_api {
    void *(*open)(uint32_t device, const mead_sdl_audio_spec *spec, audio_stream_callback callback, void *user);
    bool (*resume)(void *stream);
    bool (*pause)(void *stream);
    void (*destroy)(void *stream);
    bool (*put)(void *stream, const void *data, int bytes);
    int (*get)(void *stream, void *data, int bytes);
    int (*queued)(void *stream);
    int (*available)(void *stream);
    bool (*clear)(void *stream);
    bool (*set_gain)(void *stream, float gain);
    const char *(*error)(void);
} audio_api;

// SDL's audio functions, with its audio subsystem running; NULL if it can't.
const audio_api *audio_backend(void);

// Readies the calling thread to run Android code: SDL's audio threads call
// back into apps, and the app's thread-locals must be there when they do.
void audio_prepare_thread(void);

#endif
