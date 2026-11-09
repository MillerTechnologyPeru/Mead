// OpenSL ES, as Android has it: an engine, an output mix, and PCM players and
// recorders fed through Android's simple buffer queue. That is the whole of
// what games and FMOD use it for. Objects are structures whose interfaces are
// pointers to tables, and an interface is a pointer to one of those pointers.

#define _GNU_SOURCE
#include "audio_backend.h"
#include "mead_opensles.h"

#include <math.h>
#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Each ID is the address of a byte of its own; apps only hand them back.
#define ID(name) static const char id_##name; const SLInterfaceID SL_IID_##name = &id_##name;
#include "sl_interface_ids.inc"
#undef ID

#define METHOD(function) ((SLresult (*)())(function))

static SLresult unsupported(void) {
    return SL_RESULT_FEATURE_UNSUPPORTED;
}

static SLresult nothing_to_do(void) {
    return SL_RESULT_SUCCESS;
}

// What every object has first, so that an SLObjectItf points at its table.
typedef struct object {
    const struct SLObjectItf_ *object_table;
    uint32_t state;
    SLresult (*realize)(struct object *);
    void (*release)(struct object *);
    void *(*interface_for)(struct object *, SLInterfaceID);
} object;

#define CONTAINER(pointer, type, field) ((type *)((char *)(pointer) - offsetof(type, field)))

static SLresult object_realize(object **self, uint32_t async) {
    (void)async;
    object *target = CONTAINER(self, object, object_table);
    if (target->state == SL_OBJECT_STATE_REALIZED)
        return SL_RESULT_PRECONDITIONS_VIOLATED;
    SLresult result = target->realize ? target->realize(target) : SL_RESULT_SUCCESS;
    if (result == SL_RESULT_SUCCESS)
        target->state = SL_OBJECT_STATE_REALIZED;
    return result;
}

static SLresult object_get_state(object **self, uint32_t *state) {
    *state = CONTAINER(self, object, object_table)->state;
    return SL_RESULT_SUCCESS;
}

static SLresult object_get_interface(object **self, SLInterfaceID id, void *out) {
    object *target = CONTAINER(self, object, object_table);
    if (target->state != SL_OBJECT_STATE_REALIZED)
        return SL_RESULT_PRECONDITIONS_VIOLATED;
    void *found = id == SL_IID_OBJECT ? (void *)&target->object_table : target->interface_for(target, id);
    if (!found)
        return SL_RESULT_FEATURE_UNSUPPORTED;
    *(void **)out = found;
    return SL_RESULT_SUCCESS;
}

static void object_destroy(object **self) {
    object *target = CONTAINER(self, object, object_table);
    if (target->release)
        target->release(target);
    free(target);
}

static const struct SLObjectItf_ object_table = {
    .Realize = METHOD(object_realize),
    .Resume = METHOD(nothing_to_do),
    .GetState = METHOD(object_get_state),
    .GetInterface = METHOD(object_get_interface),
    .RegisterCallback = METHOD(nothing_to_do),
    .AbortAsyncOperation = (void (*)())nothing_to_do,
    .Destroy = (void (*)())object_destroy,
    .SetPriority = METHOD(nothing_to_do),
    .GetPriority = METHOD(unsupported),
    .SetLossOfControlInterfaces = METHOD(nothing_to_do),
};

// A format an app describes, as SDL's; false if SDL has no such thing.
static bool audio_spec_from(const void *format, mead_sdl_audio_spec *spec) {
    if (!format)
        return false;
    const SLAndroidDataFormat_PCM_EX *pcm = format;
    if (pcm->formatType != SL_DATAFORMAT_PCM && pcm->formatType != SL_ANDROID_DATAFORMAT_PCM_EX)
        return false;
    bool is_float = pcm->formatType == SL_ANDROID_DATAFORMAT_PCM_EX && pcm->representation == SL_ANDROID_PCM_REPRESENTATION_FLOAT;
    switch (pcm->bitsPerSample) {
    case 8: spec->format = MEAD_SDL_AUDIO_U8; break;
    case 16: spec->format = MEAD_SDL_AUDIO_S16LE; break;
    case 32: spec->format = is_float ? MEAD_SDL_AUDIO_F32LE : MEAD_SDL_AUDIO_S32LE; break;
    default: return false;
    }
    spec->channels = (int32_t)pcm->numChannels;
    spec->freq = (int32_t)(pcm->sampleRate / 1000); // OpenSL counts millihertz
    return spec->channels > 0 && spec->freq > 0;
}

static bool interfaces_supported(uint32_t count, const SLInterfaceID *ids, const uint32_t *required,
                                 bool (*supported)(SLInterfaceID)) {
    for (uint32_t index = 0; index < count; index++)
        if (required && required[index] && !supported(ids[index]))
            return false;
    return true;
}

// A buffer queue, common to players and recorders: the app's buffers in
// order, each used until it is full or empty and then handed back.
typedef struct pending_buffer {
    void *data;
    int size;
    int offset;
} pending_buffer;

typedef struct stream_object {
    object base;
    const struct SLPlayItf_ *play_table;           // or nothing, in a recorder
    const struct SLRecordItf_ *record_table;       // or nothing, in a player
    const struct SLAndroidSimpleBufferQueueItf_ *queue_table;
    const struct SLVolumeItf_ *volume_table;
    const struct SLAndroidConfigurationItf_ *configuration_table;

    pthread_mutex_t lock;
    const audio_api *audio;
    mead_sdl_audio_spec spec;
    void *stream;
    bool recording;
    uint32_t state;
    pending_buffer *buffers;
    uint32_t capacity, head, count;
    uint64_t total_enqueued;
    uint64_t generation; // moves on when the queue is cleared
    uint64_t bytes_done;
    void (*callback)(void *, void *);
    void *context;
    SLmillibel level;
    bool muted;
} stream_object;

static int bytes_per_frame(const mead_sdl_audio_spec *spec) {
    return (spec->format & 0xff) / 8 * spec->channels;
}

// One buffer's worth of progress, and the app told if that finished it.
// Which way the data moves is `transfer`'s business.
static void run_queue(stream_object *self, void *stream, int amount) {
    audio_prepare_thread();
    while (amount > 0) {
        pthread_mutex_lock(&self->lock);
        uint32_t active = self->recording ? SL_RECORDSTATE_RECORDING : SL_PLAYSTATE_PLAYING;
        if (self->count == 0 || self->state != active) {
            pthread_mutex_unlock(&self->lock);
            return;
        }
        pending_buffer buffer = self->buffers[self->head];
        uint64_t generation = self->generation;
        pthread_mutex_unlock(&self->lock);

        int bytes = buffer.size - buffer.offset;
        if (bytes > amount)
            bytes = amount;
        char *at = (char *)buffer.data + buffer.offset;
        if (self->recording) {
            bytes = self->audio->get(stream, at, bytes);
            if (bytes <= 0)
                return;
        } else {
            self->audio->put(stream, at, bytes);
        }
        amount -= bytes;

        bool finished = false;
        pthread_mutex_lock(&self->lock);
        if (self->generation == generation) {
            pending_buffer *current = &self->buffers[self->head];
            current->offset += bytes;
            self->bytes_done += (uint64_t)bytes;
            if (current->offset >= current->size) {
                self->head = (self->head + 1) % self->capacity;
                self->count--;
                finished = true;
            }
        }
        void (*callback)(void *, void *) = self->callback;
        void *context = self->context;
        pthread_mutex_unlock(&self->lock);
        if (finished && callback)
            callback(&self->queue_table, context);
    }
}

// SDL's call for more, on its audio thread: `additional` is what it wants now.
static void player_stream(void *user, void *stream, int additional, int total) {
    (void)total;
    run_queue(user, stream, additional);
}

// And its call to say recorded data is waiting.
static void recorder_stream(void *user, void *stream, int additional, int total) {
    (void)total;
    run_queue(user, stream, additional);
}

static SLresult stream_realize(object *base) {
    stream_object *self = (stream_object *)base;
    self->audio = audio_backend();
    if (!self->audio)
        return SL_RESULT_RESOURCE_ERROR;
    self->stream = self->audio->open(
        self->recording ? MEAD_SDL_AUDIO_DEVICE_DEFAULT_RECORDING : MEAD_SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
        &self->spec, self->recording ? recorder_stream : player_stream, self);
    if (!self->stream) {
        fprintf(stderr, "mead: OpenSL ES: %s\n", self->audio->error());
        return SL_RESULT_RESOURCE_ERROR;
    }
    return SL_RESULT_SUCCESS;
}

static void stream_release(object *base) {
    stream_object *self = (stream_object *)base;
    if (self->stream)
        self->audio->destroy(self->stream);
    pthread_mutex_destroy(&self->lock);
    free(self->buffers);
}

static void *stream_interface_for(object *base, SLInterfaceID id) {
    stream_object *self = (stream_object *)base;
    if (id == SL_IID_PLAY && !self->recording)
        return &self->play_table;
    if (id == SL_IID_RECORD && self->recording)
        return &self->record_table;
    if (id == SL_IID_ANDROIDSIMPLEBUFFERQUEUE || id == SL_IID_BUFFERQUEUE)
        return &self->queue_table;
    if (id == SL_IID_VOLUME && !self->recording)
        return &self->volume_table;
    if (id == SL_IID_ANDROIDCONFIGURATION)
        return &self->configuration_table;
    return NULL;
}

static void set_running(stream_object *self, uint32_t state, uint32_t running) {
    pthread_mutex_lock(&self->lock);
    self->state = state;
    if (state == (self->recording ? (uint32_t)SL_RECORDSTATE_STOPPED : (uint32_t)SL_PLAYSTATE_STOPPED))
        self->bytes_done = 0;
    pthread_mutex_unlock(&self->lock);
    if (state == running)
        self->audio->resume(self->stream);
    else
        self->audio->pause(self->stream);
}

static uint32_t position_milliseconds(stream_object *self) {
    pthread_mutex_lock(&self->lock);
    uint64_t bytes = self->bytes_done;
    pthread_mutex_unlock(&self->lock);
    return (uint32_t)(bytes * 1000 / (uint64_t)bytes_per_frame(&self->spec) / (uint64_t)self->spec.freq);
}

// SLPlayItf.
static SLresult play_set_state(void *self, uint32_t state) {
    set_running(CONTAINER(self, stream_object, play_table), state, SL_PLAYSTATE_PLAYING);
    return SL_RESULT_SUCCESS;
}

static SLresult play_get_state(void *self, uint32_t *state) {
    *state = CONTAINER(self, stream_object, play_table)->state;
    return SL_RESULT_SUCCESS;
}

static SLresult play_get_duration(void *self, uint32_t *duration) {
    (void)self;
    *duration = 0xFFFFFFFFu; // SL_TIME_UNKNOWN: a queue has no end
    return SL_RESULT_SUCCESS;
}

static SLresult play_get_position(void *self, uint32_t *position) {
    *position = position_milliseconds(CONTAINER(self, stream_object, play_table));
    return SL_RESULT_SUCCESS;
}

static const struct SLPlayItf_ play_table = {
    .SetPlayState = METHOD(play_set_state),
    .GetPlayState = METHOD(play_get_state),
    .GetDuration = METHOD(play_get_duration),
    .GetPosition = METHOD(play_get_position),
    .RegisterCallback = METHOD(nothing_to_do),
    .SetCallbackEventsMask = METHOD(nothing_to_do),
    .GetCallbackEventsMask = METHOD(unsupported),
    .SetMarkerPosition = METHOD(unsupported),
    .ClearMarkerPosition = METHOD(nothing_to_do),
    .GetMarkerPosition = METHOD(unsupported),
    .SetPositionUpdatePeriod = METHOD(nothing_to_do),
    .GetPositionUpdatePeriod = METHOD(unsupported),
};

// SLRecordItf.
static SLresult record_set_state(void *self, uint32_t state) {
    set_running(CONTAINER(self, stream_object, record_table), state, SL_RECORDSTATE_RECORDING);
    return SL_RESULT_SUCCESS;
}

static SLresult record_get_state(void *self, uint32_t *state) {
    *state = CONTAINER(self, stream_object, record_table)->state;
    return SL_RESULT_SUCCESS;
}

static SLresult record_get_position(void *self, uint32_t *position) {
    *position = position_milliseconds(CONTAINER(self, stream_object, record_table));
    return SL_RESULT_SUCCESS;
}

static const struct SLRecordItf_ record_table = {
    .SetRecordState = METHOD(record_set_state),
    .GetRecordState = METHOD(record_get_state),
    .SetDurationLimit = METHOD(nothing_to_do),
    .GetPosition = METHOD(record_get_position),
    .RegisterCallback = METHOD(nothing_to_do),
    .SetCallbackEventsMask = METHOD(nothing_to_do),
    .GetCallbackEventsMask = METHOD(unsupported),
    .SetMarkerPosition = METHOD(unsupported),
    .ClearMarkerPosition = METHOD(nothing_to_do),
    .GetMarkerPosition = METHOD(unsupported),
    .SetPositionUpdatePeriod = METHOD(nothing_to_do),
    .GetPositionUpdatePeriod = METHOD(unsupported),
};

// SLAndroidSimpleBufferQueueItf.
static SLresult queue_enqueue(void *pointer, void *data, uint32_t size) {
    stream_object *self = CONTAINER(pointer, stream_object, queue_table);
    if (!data || size == 0)
        return SL_RESULT_PARAMETER_INVALID;
    pthread_mutex_lock(&self->lock);
    SLresult result = SL_RESULT_BUFFER_INSUFFICIENT;
    if (self->count < self->capacity) {
        uint32_t tail = (self->head + self->count) % self->capacity;
        self->buffers[tail] = (pending_buffer){ data, (int)size, 0 };
        self->count++;
        self->total_enqueued++;
        result = SL_RESULT_SUCCESS;
    }
    pthread_mutex_unlock(&self->lock);
    return result;
}

static SLresult queue_clear(void *pointer) {
    stream_object *self = CONTAINER(pointer, stream_object, queue_table);
    pthread_mutex_lock(&self->lock);
    self->head = 0;
    self->count = 0;
    self->generation++;
    pthread_mutex_unlock(&self->lock);
    // Outside the lock: SDL holds its own while it calls run_queue.
    if (self->stream)
        self->audio->clear(self->stream);
    return SL_RESULT_SUCCESS;
}

typedef struct queue_state {
    uint32_t count;
    uint32_t index;
} queue_state;

static SLresult queue_get_state(void *pointer, queue_state *state) {
    stream_object *self = CONTAINER(pointer, stream_object, queue_table);
    pthread_mutex_lock(&self->lock);
    state->count = self->count;
    state->index = (uint32_t)(self->total_enqueued - self->count);
    pthread_mutex_unlock(&self->lock);
    return SL_RESULT_SUCCESS;
}

static SLresult queue_register_callback(void *pointer, void (*callback)(void *, void *), void *context) {
    stream_object *self = CONTAINER(pointer, stream_object, queue_table);
    pthread_mutex_lock(&self->lock);
    self->callback = callback;
    self->context = context;
    pthread_mutex_unlock(&self->lock);
    return SL_RESULT_SUCCESS;
}

static const struct SLAndroidSimpleBufferQueueItf_ queue_table_value = {
    .Enqueue = METHOD(queue_enqueue),
    .Clear = METHOD(queue_clear),
    .GetState = METHOD(queue_get_state),
    .RegisterCallback = METHOD(queue_register_callback),
};

// SLVolumeItf, in thousandths of a bel, down from 0.
static void apply_volume(stream_object *self) {
    if (self->stream)
        self->audio->set_gain(self->stream, self->muted ? 0.0f : (float)pow(10.0, self->level / 2000.0));
}

static SLresult volume_set(void *pointer, SLmillibel level) {
    stream_object *self = CONTAINER(pointer, stream_object, volume_table);
    self->level = level;
    apply_volume(self);
    return SL_RESULT_SUCCESS;
}

static SLresult volume_get(void *pointer, SLmillibel *level) {
    *level = CONTAINER(pointer, stream_object, volume_table)->level;
    return SL_RESULT_SUCCESS;
}

static SLresult volume_max(void *pointer, SLmillibel *level) {
    (void)pointer;
    *level = 0;
    return SL_RESULT_SUCCESS;
}

static SLresult volume_set_mute(void *pointer, uint32_t mute) {
    stream_object *self = CONTAINER(pointer, stream_object, volume_table);
    self->muted = mute != 0;
    apply_volume(self);
    return SL_RESULT_SUCCESS;
}

static SLresult volume_get_mute(void *pointer, uint32_t *mute) {
    *mute = CONTAINER(pointer, stream_object, volume_table)->muted;
    return SL_RESULT_SUCCESS;
}

static const struct SLVolumeItf_ volume_table = {
    .SetVolumeLevel = METHOD(volume_set),
    .GetVolumeLevel = METHOD(volume_get),
    .GetMaxVolumeLevel = METHOD(volume_max),
    .SetMute = METHOD(volume_set_mute),
    .GetMute = METHOD(volume_get_mute),
    .EnableStereoPosition = METHOD(unsupported),
    .IsEnabledStereoPosition = METHOD(unsupported),
    .SetStereoPosition = METHOD(unsupported),
    .GetStereoPosition = METHOD(unsupported),
};

// SLAndroidConfigurationItf: stream types and recording presets, which a
// desktop has no use for. They are accepted, and forgotten.
static const struct SLAndroidConfigurationItf_ configuration_table = {
    .SetConfiguration = METHOD(nothing_to_do),
    .GetConfiguration = METHOD(unsupported),
    .AcquireJavaProxy = METHOD(unsupported),
    .ReleaseJavaProxy = METHOD(unsupported),
};

static bool stream_supports(SLInterfaceID id) {
    return id == SL_IID_PLAY || id == SL_IID_RECORD || id == SL_IID_ANDROIDSIMPLEBUFFERQUEUE ||
           id == SL_IID_BUFFERQUEUE || id == SL_IID_VOLUME || id == SL_IID_ANDROIDCONFIGURATION ||
           id == SL_IID_OBJECT;
}

static SLresult create_stream(object ***out, bool recording, const SLDataLocator_BufferQueue *locator, const void *format,
                              uint32_t count, const SLInterfaceID *ids, const uint32_t *required) {
    if (!out || !locator)
        return SL_RESULT_PARAMETER_INVALID;
    if (!interfaces_supported(count, ids, required, stream_supports))
        return SL_RESULT_FEATURE_UNSUPPORTED;
    stream_object *self = calloc(1, sizeof(*self));
    if (!self)
        return SL_RESULT_MEMORY_FAILURE;
    if (!audio_spec_from(format, &self->spec)) {
        free(self);
        return SL_RESULT_CONTENT_UNSUPPORTED;
    }
    self->capacity = locator->numBuffers ? locator->numBuffers : 1;
    self->buffers = calloc(self->capacity, sizeof(*self->buffers));
    if (!self->buffers) {
        free(self);
        return SL_RESULT_MEMORY_FAILURE;
    }
    self->base.object_table = &object_table;
    self->base.state = SL_OBJECT_STATE_UNREALIZED;
    self->base.realize = stream_realize;
    self->base.release = stream_release;
    self->base.interface_for = stream_interface_for;
    self->play_table = &play_table;
    self->record_table = &record_table;
    self->queue_table = &queue_table_value;
    self->volume_table = &volume_table;
    self->configuration_table = &configuration_table;
    self->recording = recording;
    self->state = recording ? (uint32_t)SL_RECORDSTATE_STOPPED : (uint32_t)SL_PLAYSTATE_STOPPED;
    pthread_mutex_init(&self->lock, NULL);
    *out = (object **)&self->base.object_table;
    return SL_RESULT_SUCCESS;
}

// The output mix: all a player's sink ever is, and it mixes nothing itself.
typedef struct mix_object {
    object base;
} mix_object;

static void *no_interfaces(object *base, SLInterfaceID id) {
    (void)base, (void)id;
    return NULL;
}

// SLEngineItf.
typedef struct engine_object {
    object base;
    const struct SLEngineItf_ *engine_table;
} engine_object;

static SLresult engine_create_player(void *self, object ***player, const SLDataSource *source, const SLDataSink *sink,
                                     uint32_t count, const SLInterfaceID *ids, const uint32_t *required) {
    (void)self, (void)sink;
    if (!source)
        return SL_RESULT_PARAMETER_INVALID;
    return create_stream(player, false, source->pLocator, source->pFormat, count, ids, required);
}

static SLresult engine_create_recorder(void *self, object ***recorder, const SLDataSource *source, const SLDataSink *sink,
                                       uint32_t count, const SLInterfaceID *ids, const uint32_t *required) {
    (void)self, (void)source;
    if (!sink)
        return SL_RESULT_PARAMETER_INVALID;
    return create_stream(recorder, true, sink->pLocator, sink->pFormat, count, ids, required);
}

static SLresult engine_create_output_mix(void *self, object ***mix, uint32_t count, const SLInterfaceID *ids, const uint32_t *required) {
    (void)self, (void)count, (void)ids, (void)required;
    mix_object *created = calloc(1, sizeof(*created));
    if (!created)
        return SL_RESULT_MEMORY_FAILURE;
    created->base.object_table = &object_table;
    created->base.state = SL_OBJECT_STATE_UNREALIZED;
    created->base.interface_for = no_interfaces;
    *mix = (object **)&created->base.object_table;
    return SL_RESULT_SUCCESS;
}

static const struct SLEngineItf_ engine_table = {
    .CreateLEDDevice = METHOD(unsupported),
    .CreateVibraDevice = METHOD(unsupported),
    .CreateAudioPlayer = METHOD(engine_create_player),
    .CreateAudioRecorder = METHOD(engine_create_recorder),
    .CreateMidiPlayer = METHOD(unsupported),
    .CreateListener = METHOD(unsupported),
    .Create3DGroup = METHOD(unsupported),
    .CreateOutputMix = METHOD(engine_create_output_mix),
    .CreateMetadataExtractor = METHOD(unsupported),
    .CreateExtensionObject = METHOD(unsupported),
    .QueryNumSupportedInterfaces = METHOD(unsupported),
    .QuerySupportedInterfaces = METHOD(unsupported),
    .QueryNumSupportedExtensions = METHOD(unsupported),
    .QuerySupportedExtension = METHOD(unsupported),
    .IsExtensionSupported = METHOD(unsupported),
};

static void *engine_interface_for(object *base, SLInterfaceID id) {
    return id == SL_IID_ENGINE ? &((engine_object *)base)->engine_table : NULL;
}

SLresult slCreateEngine(object ***engine, uint32_t option_count, const void *options, uint32_t count,
                        const SLInterfaceID *ids, const uint32_t *required) {
    (void)option_count, (void)options, (void)count, (void)ids, (void)required;
    if (!engine)
        return SL_RESULT_PARAMETER_INVALID;
    engine_object *created = calloc(1, sizeof(*created));
    if (!created)
        return SL_RESULT_MEMORY_FAILURE;
    created->base.object_table = &object_table;
    created->base.state = SL_OBJECT_STATE_UNREALIZED;
    created->base.interface_for = engine_interface_for;
    created->engine_table = &engine_table;
    *engine = (object **)&created->base.object_table;
    return SL_RESULT_SUCCESS;
}
