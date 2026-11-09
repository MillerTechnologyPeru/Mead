// AAudio: streams opened from a builder, either pulled from through a data
// callback or written to and read from. On SDL's audio streams each kind is
// a short step.

#define _GNU_SOURCE
#include "audio_backend.h"

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum {
    AAUDIO_OK = 0,
    AAUDIO_ERROR_DISCONNECTED = -899,
    AAUDIO_ERROR_ILLEGAL_ARGUMENT = -898,
    AAUDIO_ERROR_INTERNAL = -896,
    AAUDIO_ERROR_INVALID_STATE = -895,
    AAUDIO_ERROR_UNAVAILABLE = -889,
    AAUDIO_ERROR_NO_MEMORY = -887,
    AAUDIO_ERROR_TIMEOUT = -885,
    AAUDIO_ERROR_INVALID_FORMAT = -883,

    AAUDIO_UNSPECIFIED = 0,
    AAUDIO_FORMAT_PCM_I16 = 1,
    AAUDIO_FORMAT_PCM_FLOAT = 2,
    AAUDIO_FORMAT_PCM_I32 = 4,

    AAUDIO_DIRECTION_OUTPUT = 0,
    AAUDIO_DIRECTION_INPUT = 1,

    AAUDIO_STREAM_STATE_OPEN = 2,
    AAUDIO_STREAM_STATE_STARTED = 4,
    AAUDIO_STREAM_STATE_PAUSED = 6,
    AAUDIO_STREAM_STATE_FLUSHED = 8,
    AAUDIO_STREAM_STATE_STOPPED = 10,
    AAUDIO_STREAM_STATE_CLOSED = 12,

    AAUDIO_CALLBACK_RESULT_CONTINUE = 0,

    DEFAULT_RATE = 48000,
    DEFAULT_CHANNELS = 2,
    BURST_FRAMES = 240,   // five milliseconds at 48 kHz, when SDL can't say what its device takes
    CAPACITY_BURSTS = 8,
};

// MEAD_TRACE=audio says what is asked of each stream.
static bool tracing(void) {
    static int wanted = -1;
    if (wanted < 0) {
        const char *list = getenv("MEAD_TRACE");
        wanted = list && (strstr(list, "audio") || strstr(list, "all"));
    }
    return wanted;
}

#define TRACE(...)                                                                         \
    do {                                                                                   \
        if (tracing()) {                                                                   \
            fprintf(stderr, "mead(audio): " __VA_ARGS__);                                  \
            fputc('\n', stderr);                                                           \
        }                                                                                  \
    } while (0)

struct stream;
typedef int32_t (*data_callback)(struct stream *, void *, void *, int32_t);
typedef void (*error_callback)(struct stream *, void *, int32_t);

typedef struct builder {
    int32_t device, rate, channels, format, direction, sharing, performance, capacity, callback_frames, session;
    data_callback data;
    void *data_user;
    error_callback error;
    void *error_user;
} builder;

typedef struct stream {
    builder settings;
    const audio_api *audio;
    void *sdl;
    pthread_mutex_t lock;
    pthread_cond_t changed;
    int32_t state;
    int32_t bytes_per_frame;
    int32_t buffer_size; // in frames
    int64_t frames_moved;
    void *scratch;
    int32_t scratch_frames;
    int32_t burst;
} stream;

int32_t AAudio_createStreamBuilder(builder **out) {
    builder *created = calloc(1, sizeof(*created));
    if (!created)
        return AAUDIO_ERROR_NO_MEMORY;
    created->direction = AAUDIO_DIRECTION_OUTPUT;
    created->session = -1; // AAUDIO_SESSION_ID_NONE
    *out = created;
    return AAUDIO_OK;
}

int32_t AAudioStreamBuilder_delete(builder *self) {
    free(self);
    return AAUDIO_OK;
}

#define SETTER(name, field)                                                                \
    void AAudioStreamBuilder_##name(builder *self, int32_t value) { self->field = value; }

SETTER(setDeviceId, device)
SETTER(setSampleRate, rate)
SETTER(setChannelCount, channels)
SETTER(setSamplesPerFrame, channels)
SETTER(setFormat, format)
SETTER(setDirection, direction)
SETTER(setSharingMode, sharing)
SETTER(setPerformanceMode, performance)
SETTER(setBufferCapacityInFrames, capacity)
SETTER(setFramesPerDataCallback, callback_frames)
SETTER(setSessionId, session)

#define IGNORED(name)                                                                      \
    void AAudioStreamBuilder_##name(builder *self, int32_t value) { (void)self, (void)value; }

IGNORED(setUsage)
IGNORED(setContentType)
IGNORED(setInputPreset)
IGNORED(setAllowedCapturePolicy)
IGNORED(setPrivacySensitive)
IGNORED(setChannelMask)

void AAudioStreamBuilder_setDataCallback(builder *self, data_callback callback, void *user) {
    self->data = callback;
    self->data_user = user;
}

void AAudioStreamBuilder_setErrorCallback(builder *self, error_callback callback, void *user) {
    self->error = callback;
    self->error_user = user;
}

static int sdl_format(int32_t format) {
    switch (format) {
    case AAUDIO_FORMAT_PCM_I16: return MEAD_SDL_AUDIO_S16LE;
    case AAUDIO_FORMAT_PCM_FLOAT: return MEAD_SDL_AUDIO_F32LE;
    case AAUDIO_FORMAT_PCM_I32: return MEAD_SDL_AUDIO_S32LE;
    default: return 0;
    }
}

static int32_t bytes_per_sample(int32_t format) {
    return format == AAUDIO_FORMAT_PCM_I16 ? 2 : 4;
}

static void set_state(stream *self, int32_t state) {
    pthread_mutex_lock(&self->lock);
    self->state = state;
    pthread_cond_broadcast(&self->changed);
    pthread_mutex_unlock(&self->lock);
}

static int32_t get_state(stream *self) {
    pthread_mutex_lock(&self->lock);
    int32_t state = self->state;
    pthread_mutex_unlock(&self->lock);
    return state;
}

// SDL's call for more or to say there is more, for a data callback stream.
static void callback_stream(void *user, void *sdl, int additional, int total) {
    (void)total;
    audio_prepare_thread();
    stream *self = user;
    if (get_state(self) != AAUDIO_STREAM_STATE_STARTED)
        return;
    bool input = self->settings.direction == AAUDIO_DIRECTION_INPUT;
    int32_t frames = additional / self->bytes_per_frame;
    while (frames > 0) {
        int32_t chunk = self->settings.callback_frames > 0 ? self->settings.callback_frames
                        : frames < self->scratch_frames ? frames : self->scratch_frames;
        if (chunk > self->scratch_frames)
            chunk = self->scratch_frames;
        if (input && self->audio->get(sdl, self->scratch, chunk * self->bytes_per_frame) < chunk * self->bytes_per_frame)
            return;
        int32_t result = self->settings.data(self, self->settings.data_user, self->scratch, chunk);
        if (result != AAUDIO_CALLBACK_RESULT_CONTINUE)
            TRACE("data callback of %p returned %d for %d frames", (void *)self, result, chunk);
        if (!input)
            self->audio->put(sdl, self->scratch, chunk * self->bytes_per_frame);
        pthread_mutex_lock(&self->lock);
        self->frames_moved += chunk;
        pthread_mutex_unlock(&self->lock);
        frames -= chunk;
        if (result != AAUDIO_CALLBACK_RESULT_CONTINUE) {
            set_state(self, AAUDIO_STREAM_STATE_STOPPED);
            return;
        }
    }
}

int32_t AAudioStreamBuilder_openStream(builder *settings, stream **out) {
    const audio_api *audio = audio_backend();
    if (!audio)
        return AAUDIO_ERROR_UNAVAILABLE;
    stream *self = calloc(1, sizeof(*self));
    if (!self)
        return AAUDIO_ERROR_NO_MEMORY;
    self->settings = *settings;
    if (self->settings.rate == AAUDIO_UNSPECIFIED)
        self->settings.rate = DEFAULT_RATE;
    if (self->settings.channels == AAUDIO_UNSPECIFIED)
        self->settings.channels = DEFAULT_CHANNELS;
    if (self->settings.format == AAUDIO_UNSPECIFIED)
        self->settings.format = AAUDIO_FORMAT_PCM_FLOAT;
    int format = sdl_format(self->settings.format);
    if (!format) {
        free(self);
        return AAUDIO_ERROR_INVALID_FORMAT;
    }
    self->audio = audio;
    self->state = AAUDIO_STREAM_STATE_OPEN;
    self->bytes_per_frame = bytes_per_sample(self->settings.format) * self->settings.channels;
    pthread_mutex_init(&self->lock, NULL);
    pthread_cond_init(&self->changed, NULL);

    mead_sdl_audio_spec spec = { format, self->settings.channels, self->settings.rate };
    uint32_t device = self->settings.direction == AAUDIO_DIRECTION_INPUT ? MEAD_SDL_AUDIO_DEVICE_DEFAULT_RECORDING
                                                                         : MEAD_SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK;
    // Paused until it is started, so nothing is asked of a callback before then.
    self->sdl = audio->open(device, &spec, self->settings.data ? callback_stream : NULL, self);
    if (!self->sdl) {
        fprintf(stderr, "mead: AAudio: %s\n", audio->error());
        pthread_cond_destroy(&self->changed);
        pthread_mutex_destroy(&self->lock);
        free(self);
        return AAUDIO_ERROR_UNAVAILABLE;
    }

    // A burst is what the device takes at a time, as on Android, where it is
    // the mixer's period. Buffering a few of them lets a writer that is late
    // by a period or two go unheard; buffering a few of anything smaller than
    // what SDL's device takes does not.
    self->burst = audio_device_frames(self->sdl, self->settings.rate);
    if (self->burst <= 0)
        self->burst = BURST_FRAMES;
    if (self->settings.capacity <= 0)
        self->settings.capacity = self->burst * CAPACITY_BURSTS;
    self->buffer_size = self->settings.capacity;
    self->scratch_frames = self->settings.callback_frames > self->burst ? self->settings.callback_frames : self->burst;
    self->scratch = malloc((size_t)(self->scratch_frames * self->bytes_per_frame));
    if (!self->scratch) {
        audio->destroy(self->sdl);
        pthread_cond_destroy(&self->changed);
        pthread_mutex_destroy(&self->lock);
        free(self);
        return AAUDIO_ERROR_NO_MEMORY;
    }
    TRACE("open %p: %s, %d Hz, %d channels, format %d, capacity %d, burst %d, callback %s, %d frames per callback, performance %d",
          (void *)self, self->settings.direction == AAUDIO_DIRECTION_INPUT ? "input" : "output", self->settings.rate,
          self->settings.channels, self->settings.format, self->settings.capacity, self->burst,
          self->settings.data ? "yes" : "no", self->settings.callback_frames, self->settings.performance);
    *out = self;
    return AAUDIO_OK;
}

int32_t AAudioStream_close(stream *self) {
    TRACE("close %p after %lld frames", (void *)self, (long long)self->frames_moved);
    set_state(self, AAUDIO_STREAM_STATE_CLOSED);
    self->audio->destroy(self->sdl);
    pthread_cond_destroy(&self->changed);
    pthread_mutex_destroy(&self->lock);
    free(self->scratch);
    free(self);
    return AAUDIO_OK;
}

int32_t AAudioStream_release(stream *self) {
    (void)self;
    return AAUDIO_OK; // close does both here
}

int32_t AAudioStream_requestStart(stream *self) {
    set_state(self, AAUDIO_STREAM_STATE_STARTED);
    bool resumed = self->audio->resume(self->sdl);
    TRACE("start %p: %s", (void *)self, resumed ? "ok" : self->audio->error());
    return resumed ? AAUDIO_OK : AAUDIO_ERROR_INTERNAL;
}

int32_t AAudioStream_requestPause(stream *self) {
    self->audio->pause(self->sdl);
    set_state(self, AAUDIO_STREAM_STATE_PAUSED);
    return AAUDIO_OK;
}

int32_t AAudioStream_requestFlush(stream *self) {
    if (get_state(self) == AAUDIO_STREAM_STATE_STARTED)
        return AAUDIO_ERROR_INVALID_STATE;
    self->audio->clear(self->sdl);
    set_state(self, AAUDIO_STREAM_STATE_FLUSHED);
    return AAUDIO_OK;
}

int32_t AAudioStream_requestStop(stream *self) {
    TRACE("stop %p", (void *)self);
    self->audio->pause(self->sdl);
    set_state(self, AAUDIO_STREAM_STATE_STOPPED);
    return AAUDIO_OK;
}

int32_t AAudioStream_getState(stream *self) {
    TRACE("state of %p is %d", (void *)self, get_state(self));
    return get_state(self);
}

static int64_t now_nanoseconds(clockid_t clock) {
    struct timespec time;
    clock_gettime(clock, &time);
    return (int64_t)time.tv_sec * 1000000000 + time.tv_nsec;
}

int32_t AAudioStream_waitForStateChange(stream *self, int32_t input, int32_t *next, int64_t timeout) {
    int64_t deadline = now_nanoseconds(CLOCK_MONOTONIC) + timeout;
    int32_t state;
    while ((state = get_state(self)) == input) {
        if (now_nanoseconds(CLOCK_MONOTONIC) >= deadline)
            return AAUDIO_ERROR_TIMEOUT;
        usleep(1000);
    }
    if (next)
        *next = state;
    return AAUDIO_OK;
}

// Blocking, for streams without a data callback.
int32_t AAudioStream_write(stream *self, const void *buffer, int32_t frames, int64_t timeout) {
    int64_t deadline = now_nanoseconds(CLOCK_MONOTONIC) + timeout;
    int32_t written = 0;
    const char *at = buffer;
    while (written < frames) {
        int room = self->buffer_size * self->bytes_per_frame - self->audio->queued(self->sdl);
        int32_t count = room / self->bytes_per_frame;
        if (count > frames - written)
            count = frames - written;
        if (count > 0) {
            if (!self->audio->put(self->sdl, at, count * self->bytes_per_frame))
                return AAUDIO_ERROR_INTERNAL;
            at += count * self->bytes_per_frame;
            written += count;
            continue;
        }
        if (now_nanoseconds(CLOCK_MONOTONIC) >= deadline)
            break;
        usleep(1000);
    }
    pthread_mutex_lock(&self->lock);
    self->frames_moved += written;
    pthread_mutex_unlock(&self->lock);
    return written;
}

int32_t AAudioStream_read(stream *self, void *buffer, int32_t frames, int64_t timeout) {
    int64_t deadline = now_nanoseconds(CLOCK_MONOTONIC) + timeout;
    int32_t got = 0;
    char *at = buffer;
    while (got < frames) {
        int bytes = self->audio->get(self->sdl, at, (frames - got) * self->bytes_per_frame);
        int32_t count = bytes > 0 ? bytes / self->bytes_per_frame : 0;
        if (count > 0) {
            at += count * self->bytes_per_frame;
            got += count;
            continue;
        }
        if (now_nanoseconds(CLOCK_MONOTONIC) >= deadline)
            break;
        usleep(1000);
    }
    pthread_mutex_lock(&self->lock);
    self->frames_moved += got;
    pthread_mutex_unlock(&self->lock);
    return got;
}

int32_t AAudioStream_setBufferSizeInFrames(stream *self, int32_t frames) {
    TRACE("set buffer size of %p to %d (capacity %d)", (void *)self, frames, self->settings.capacity);
    if (frames < 1)
        frames = 1;
    if (frames > self->settings.capacity)
        frames = self->settings.capacity;
    self->buffer_size = frames;
    return frames;
}

#define GETTER(name, value)                                                                \
    int32_t AAudioStream_##name(stream *self) { return (value); }

GETTER(getBufferSizeInFrames, self->buffer_size)
GETTER(getBufferCapacityInFrames, self->settings.capacity)
GETTER(getFramesPerBurst, self->burst)
GETTER(getFramesPerDataCallback, self->settings.callback_frames)
GETTER(getXRunCount, 0)
GETTER(getSampleRate, self->settings.rate)
GETTER(getChannelCount, self->settings.channels)
GETTER(getSamplesPerFrame, self->settings.channels)
GETTER(getFormat, self->settings.format)
GETTER(getDirection, self->settings.direction)
GETTER(getSharingMode, self->settings.sharing)
GETTER(getPerformanceMode, self->settings.performance)
GETTER(getDeviceId, 0)
GETTER(getSessionId, self->settings.session)

static int64_t frames_moved(stream *self) {
    pthread_mutex_lock(&self->lock);
    int64_t frames = self->frames_moved;
    pthread_mutex_unlock(&self->lock);
    return frames;
}

// Frames in SDL's stream between the app and the device: written by the
// app and not yet taken by the device, for output; taken from the device and
// not yet read by the app, for input.
static int64_t frames_waiting(stream *self) {
    int bytes = self->settings.direction == AAUDIO_DIRECTION_INPUT ? self->audio->available(self->sdl)
                                                                    : self->audio->queued(self->sdl);
    return bytes > 0 ? bytes / self->bytes_per_frame : 0;
}

// As on Android: frames written by whichever side writes, the app for output
// and the device for input, and read by the other.
int64_t AAudioStream_getFramesWritten(stream *self) {
    int64_t moved = frames_moved(self);
    return self->settings.direction == AAUDIO_DIRECTION_INPUT ? moved + frames_waiting(self) : moved;
}

int64_t AAudioStream_getFramesRead(stream *self) {
    int64_t moved = frames_moved(self);
    if (self->settings.direction == AAUDIO_DIRECTION_INPUT)
        return moved;
    int64_t read = moved - frames_waiting(self);
    return read > 0 ? read : 0;
}

// The frame at the device now: what it has taken, either way.
int32_t AAudioStream_getTimestamp(stream *self, clockid_t clock, int64_t *position, int64_t *time) {
    *position = self->settings.direction == AAUDIO_DIRECTION_INPUT ? AAudioStream_getFramesWritten(self)
                                                                   : AAudioStream_getFramesRead(self);
    *time = now_nanoseconds(clock);
    return AAUDIO_OK;
}

const char *AAudio_convertResultToText(int32_t result) {
    switch (result) {
    case AAUDIO_OK: return "AAUDIO_OK";
    case AAUDIO_ERROR_DISCONNECTED: return "AAUDIO_ERROR_DISCONNECTED";
    case AAUDIO_ERROR_ILLEGAL_ARGUMENT: return "AAUDIO_ERROR_ILLEGAL_ARGUMENT";
    case AAUDIO_ERROR_INTERNAL: return "AAUDIO_ERROR_INTERNAL";
    case AAUDIO_ERROR_INVALID_STATE: return "AAUDIO_ERROR_INVALID_STATE";
    case AAUDIO_ERROR_UNAVAILABLE: return "AAUDIO_ERROR_UNAVAILABLE";
    case AAUDIO_ERROR_NO_MEMORY: return "AAUDIO_ERROR_NO_MEMORY";
    case AAUDIO_ERROR_TIMEOUT: return "AAUDIO_ERROR_TIMEOUT";
    case AAUDIO_ERROR_INVALID_FORMAT: return "AAUDIO_ERROR_INVALID_FORMAT";
    default: return "Unrecognized AAudio error";
    }
}

const char *AAudio_convertStreamStateToText(int32_t state) {
    switch (state) {
    case AAUDIO_STREAM_STATE_OPEN: return "AAUDIO_STREAM_STATE_OPEN";
    case AAUDIO_STREAM_STATE_STARTED: return "AAUDIO_STREAM_STATE_STARTED";
    case AAUDIO_STREAM_STATE_PAUSED: return "AAUDIO_STREAM_STATE_PAUSED";
    case AAUDIO_STREAM_STATE_FLUSHED: return "AAUDIO_STREAM_STATE_FLUSHED";
    case AAUDIO_STREAM_STATE_STOPPED: return "AAUDIO_STREAM_STATE_STOPPED";
    case AAUDIO_STREAM_STATE_CLOSED: return "AAUDIO_STREAM_STATE_CLOSED";
    default: return "Unrecognized AAudio state";
    }
}
