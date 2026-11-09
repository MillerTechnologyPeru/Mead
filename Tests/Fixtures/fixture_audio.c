// mead --selftest's audio: OpenSL ES and AAudio as NDK code uses them. SDL's
// disk driver writes what is played to a file, which is read back and held
// to what was sent, and feeds a known file to whatever records.

#include <SLES/OpenSLES.h>
#include <SLES/OpenSLES_Android.h>
#include <aaudio/AAudio.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define CHECK(condition)                                                                   \
    do {                                                                                   \
        if (!(condition)) {                                                                \
            fprintf(stderr, "fixture_audio: line %d: %s\n", __LINE__, #condition);         \
            return __LINE__;                                                               \
        }                                                                                  \
    } while (0)

enum { RATE = 48000, FRAMES = 4800, ENOUGH = 8000, RECORDED = 960 };

// A ramp no silence or resampling could produce by accident.
static void fill_ramp(int16_t *samples, int frames, int first) {
    for (int index = 0; index < frames; index++) {
        samples[index * 2] = (int16_t)(first + index);
        samples[index * 2 + 1] = (int16_t)-(first + index);
    }
}

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static int finished_buffers;

// Audio callbacks run on threads the app never made, and its thread-locals
// have to be there all the same.
static __thread int thread_local_value = 77;
static int bad_thread_locals;

static void note_finished(void) {
    if (thread_local_value != 77)
        bad_thread_locals++;
    pthread_mutex_lock(&lock);
    finished_buffers++;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
}

static bool wait_for_buffers(int wanted) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 10;
    pthread_mutex_lock(&lock);
    int result = 0;
    while (finished_buffers < wanted && result == 0)
        result = pthread_cond_timedwait(&changed, &lock, &deadline);
    bool ok = finished_buffers >= wanted;
    pthread_mutex_unlock(&lock);
    return ok;
}

static void reset_buffers(void) {
    pthread_mutex_lock(&lock);
    finished_buffers = 0;
    pthread_mutex_unlock(&lock);
}

// The file SDL wrote holds the ramp, after whatever silence came first.
static int check_output(int want_frames) {
    const char *path = getenv("SDL_AUDIO_DISK_OUTPUT_FILE");
    CHECK(path != NULL);
    FILE *file = fopen(path, "rb");
    CHECK(file != NULL);
    static int16_t data[RATE * 4];
    size_t frames = fread(data, 4, RATE * 2, file);
    fclose(file);
    CHECK(frames > 0);
    size_t start = 0;
    while (start < frames && data[start * 2] == 0 && data[start * 2 + 1] == 0)
        start++;
    CHECK(start < frames);
    CHECK(data[start * 2] == 1 && data[start * 2 + 1] == -1);
    int matched = 0;
    for (size_t at = start; at < frames && matched < want_frames; at++, matched++)
        CHECK(data[at * 2] == (int16_t)(1 + matched) && data[at * 2 + 1] == (int16_t)-(1 + matched));
    CHECK(matched >= want_frames);
    return 0;
}

static int16_t play_buffers[2][FRAMES * 2];

static void played_callback(SLAndroidSimpleBufferQueueItf queue, void *context) {
    (void)queue;
    (*(int *)context)++;
    note_finished();
}

static int test_opensles_playback(void) {
    SLObjectItf engine_object;
    CHECK(slCreateEngine(&engine_object, 0, NULL, 0, NULL, NULL) == SL_RESULT_SUCCESS);
    SLEngineItf engine = NULL;
    CHECK((*engine_object)->GetInterface(engine_object, SL_IID_ENGINE, &engine) == SL_RESULT_PRECONDITIONS_VIOLATED);
    CHECK((*engine_object)->Realize(engine_object, SL_BOOLEAN_FALSE) == SL_RESULT_SUCCESS);
    SLuint32 state = 0;
    CHECK((*engine_object)->GetState(engine_object, &state) == SL_RESULT_SUCCESS && state == SL_OBJECT_STATE_REALIZED);
    CHECK((*engine_object)->GetInterface(engine_object, SL_IID_ENGINE, &engine) == SL_RESULT_SUCCESS);

    SLObjectItf mix;
    CHECK((*engine)->CreateOutputMix(engine, &mix, 0, NULL, NULL) == SL_RESULT_SUCCESS);
    CHECK((*mix)->Realize(mix, SL_BOOLEAN_FALSE) == SL_RESULT_SUCCESS);

    SLDataLocator_AndroidSimpleBufferQueue locator = { SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE, 2 };
    SLDataFormat_PCM format = {
        SL_DATAFORMAT_PCM, 2, SL_SAMPLINGRATE_48, SL_PCMSAMPLEFORMAT_FIXED_16, SL_PCMSAMPLEFORMAT_FIXED_16,
        SL_SPEAKER_FRONT_LEFT | SL_SPEAKER_FRONT_RIGHT, SL_BYTEORDER_LITTLEENDIAN,
    };
    SLDataSource source = { &locator, &format };
    SLDataLocator_OutputMix sink_locator = { SL_DATALOCATOR_OUTPUTMIX, mix };
    SLDataSink sink = { &sink_locator, NULL };

    const SLInterfaceID ids[] = { SL_IID_ANDROIDSIMPLEBUFFERQUEUE, SL_IID_VOLUME };
    const SLboolean required[] = { SL_BOOLEAN_TRUE, SL_BOOLEAN_TRUE };
    SLObjectItf player;
    CHECK((*engine)->CreateAudioPlayer(engine, &player, &source, &sink, 2, ids, required) == SL_RESULT_SUCCESS);
    CHECK((*player)->Realize(player, SL_BOOLEAN_FALSE) == SL_RESULT_SUCCESS);

    // What it has not got, it says so when it is required.
    const SLInterfaceID reverb[] = { SL_IID_ENVIRONMENTALREVERB };
    const SLboolean needed[] = { SL_BOOLEAN_TRUE };
    SLObjectItf refused;
    CHECK((*engine)->CreateAudioPlayer(engine, &refused, &source, &sink, 1, reverb, needed) == SL_RESULT_FEATURE_UNSUPPORTED);

    SLPlayItf play;
    SLAndroidSimpleBufferQueueItf queue;
    SLVolumeItf volume;
    CHECK((*player)->GetInterface(player, SL_IID_PLAY, &play) == SL_RESULT_SUCCESS);
    CHECK((*player)->GetInterface(player, SL_IID_ANDROIDSIMPLEBUFFERQUEUE, &queue) == SL_RESULT_SUCCESS);
    CHECK((*player)->GetInterface(player, SL_IID_VOLUME, &volume) == SL_RESULT_SUCCESS);

    static int callbacks;
    CHECK((*queue)->RegisterCallback(queue, played_callback, &callbacks) == SL_RESULT_SUCCESS);
    SLmillibel level = -1, maximum = -1;
    CHECK((*volume)->GetVolumeLevel(volume, &level) == SL_RESULT_SUCCESS && level == 0);
    CHECK((*volume)->GetMaxVolumeLevel(volume, &maximum) == SL_RESULT_SUCCESS && maximum == 0);

    fill_ramp(play_buffers[0], FRAMES, 1);
    fill_ramp(play_buffers[1], FRAMES, 1 + FRAMES);
    CHECK((*queue)->Enqueue(queue, play_buffers[0], sizeof(play_buffers[0])) == SL_RESULT_SUCCESS);
    CHECK((*queue)->Enqueue(queue, play_buffers[1], sizeof(play_buffers[1])) == SL_RESULT_SUCCESS);
    CHECK((*queue)->Enqueue(queue, play_buffers[0], sizeof(play_buffers[0])) == SL_RESULT_BUFFER_INSUFFICIENT);
    SLAndroidSimpleBufferQueueState queued;
    CHECK((*queue)->GetState(queue, &queued) == SL_RESULT_SUCCESS && queued.count == 2);

    reset_buffers();
    CHECK((*play)->SetPlayState(play, SL_PLAYSTATE_PLAYING) == SL_RESULT_SUCCESS);
    SLuint32 play_state = 0;
    CHECK((*play)->GetPlayState(play, &play_state) == SL_RESULT_SUCCESS && play_state == SL_PLAYSTATE_PLAYING);
    CHECK(wait_for_buffers(2));
    CHECK(callbacks == 2);
    CHECK(bad_thread_locals == 0);
    SLmillisecond position = 0;
    CHECK((*play)->GetPosition(play, &position) == SL_RESULT_SUCCESS && position == 200);
    CHECK((*queue)->GetState(queue, &queued) == SL_RESULT_SUCCESS && queued.count == 0 && queued.index == 2);

    usleep(400000); // what SDL holds is still to reach the file
    CHECK((*play)->SetPlayState(play, SL_PLAYSTATE_STOPPED) == SL_RESULT_SUCCESS);
    CHECK((*queue)->Clear(queue) == SL_RESULT_SUCCESS);
    (*player)->Destroy(player);
    int failed = check_output(ENOUGH);
    if (failed)
        return failed;

    (*mix)->Destroy(mix);
    (*engine_object)->Destroy(engine_object);
    return 0;
}

static int16_t record_buffer[RECORDED * 2];

static void recorded_callback(SLAndroidSimpleBufferQueueItf queue, void *context) {
    (void)queue, (void)context;
    note_finished();
}

static int test_opensles_recording(void) {
    SLObjectItf engine_object;
    SLEngineItf engine;
    CHECK(slCreateEngine(&engine_object, 0, NULL, 0, NULL, NULL) == SL_RESULT_SUCCESS);
    CHECK((*engine_object)->Realize(engine_object, SL_BOOLEAN_FALSE) == SL_RESULT_SUCCESS);
    CHECK((*engine_object)->GetInterface(engine_object, SL_IID_ENGINE, &engine) == SL_RESULT_SUCCESS);

    SLDataLocator_IODevice device = { SL_DATALOCATOR_IODEVICE, SL_IODEVICE_AUDIOINPUT, SL_DEFAULTDEVICEID_AUDIOINPUT, NULL };
    SLDataSource source = { &device, NULL };
    SLDataLocator_AndroidSimpleBufferQueue locator = { SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE, 1 };
    SLDataFormat_PCM format = {
        SL_DATAFORMAT_PCM, 2, SL_SAMPLINGRATE_48, SL_PCMSAMPLEFORMAT_FIXED_16, SL_PCMSAMPLEFORMAT_FIXED_16,
        SL_SPEAKER_FRONT_LEFT | SL_SPEAKER_FRONT_RIGHT, SL_BYTEORDER_LITTLEENDIAN,
    };
    SLDataSink sink = { &locator, &format };
    const SLInterfaceID ids[] = { SL_IID_ANDROIDSIMPLEBUFFERQUEUE, SL_IID_ANDROIDCONFIGURATION };
    const SLboolean required[] = { SL_BOOLEAN_TRUE, SL_BOOLEAN_FALSE };
    SLObjectItf recorder;
    CHECK((*engine)->CreateAudioRecorder(engine, &recorder, &source, &sink, 2, ids, required) == SL_RESULT_SUCCESS);

    SLAndroidConfigurationItf configuration;
    CHECK((*recorder)->Realize(recorder, SL_BOOLEAN_FALSE) == SL_RESULT_SUCCESS);
    CHECK((*recorder)->GetInterface(recorder, SL_IID_ANDROIDCONFIGURATION, &configuration) == SL_RESULT_SUCCESS);
    SLuint32 preset = SL_ANDROID_RECORDING_PRESET_GENERIC;
    CHECK((*configuration)->SetConfiguration(configuration, SL_ANDROID_KEY_RECORDING_PRESET, &preset, sizeof(preset)) == SL_RESULT_SUCCESS);

    SLRecordItf record;
    SLAndroidSimpleBufferQueueItf queue;
    CHECK((*recorder)->GetInterface(recorder, SL_IID_RECORD, &record) == SL_RESULT_SUCCESS);
    CHECK((*recorder)->GetInterface(recorder, SL_IID_ANDROIDSIMPLEBUFFERQUEUE, &queue) == SL_RESULT_SUCCESS);
    CHECK((*queue)->RegisterCallback(queue, recorded_callback, NULL) == SL_RESULT_SUCCESS);
    CHECK((*queue)->Enqueue(queue, record_buffer, sizeof(record_buffer)) == SL_RESULT_SUCCESS);
    reset_buffers();
    CHECK((*record)->SetRecordState(record, SL_RECORDSTATE_RECORDING) == SL_RESULT_SUCCESS);
    CHECK(wait_for_buffers(1));
    CHECK(bad_thread_locals == 0);
    CHECK((*record)->SetRecordState(record, SL_RECORDSTATE_STOPPED) == SL_RESULT_SUCCESS);
    for (int index = 0; index < RECORDED * 2; index++)
        CHECK(record_buffer[index] == 0x4141);
    (*recorder)->Destroy(recorder);
    (*engine_object)->Destroy(engine_object);
    return 0;
}

static int callback_frames_written;

static aaudio_data_callback_result_t data_callback(AAudioStream *stream, void *user, void *audio, int32_t frames) {
    (void)stream, (void)user;
    if (thread_local_value != 77)
        bad_thread_locals++;
    fill_ramp(audio, frames, 1 + callback_frames_written);
    callback_frames_written += frames;
    if (callback_frames_written >= FRAMES * 2) {
        note_finished();
        return AAUDIO_CALLBACK_RESULT_STOP;
    }
    return AAUDIO_CALLBACK_RESULT_CONTINUE;
}

static AAudioStreamBuilder *new_builder(aaudio_direction_t direction) {
    AAudioStreamBuilder *builder = NULL;
    if (AAudio_createStreamBuilder(&builder) != AAUDIO_OK)
        return NULL;
    AAudioStreamBuilder_setDirection(builder, direction);
    AAudioStreamBuilder_setSampleRate(builder, RATE);
    AAudioStreamBuilder_setChannelCount(builder, 2);
    AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setPerformanceMode(builder, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    return builder;
}

static int test_aaudio_callback(void) {
    AAudioStreamBuilder *builder = new_builder(AAUDIO_DIRECTION_OUTPUT);
    CHECK(builder != NULL);
    AAudioStreamBuilder_setDataCallback(builder, data_callback, NULL);
    AAudioStream *stream = NULL;
    CHECK(AAudioStreamBuilder_openStream(builder, &stream) == AAUDIO_OK);
    CHECK(AAudioStreamBuilder_delete(builder) == AAUDIO_OK);
    CHECK(AAudioStream_getSampleRate(stream) == RATE);
    CHECK(AAudioStream_getChannelCount(stream) == 2);
    CHECK(AAudioStream_getFormat(stream) == AAUDIO_FORMAT_PCM_I16);
    CHECK(AAudioStream_getFramesPerBurst(stream) > 0);
    CHECK(AAudioStream_getState(stream) == AAUDIO_STREAM_STATE_OPEN);

    reset_buffers();
    CHECK(AAudioStream_requestStart(stream) == AAUDIO_OK);
    CHECK(wait_for_buffers(1));
    CHECK(bad_thread_locals == 0);
    aaudio_stream_state_t next = AAUDIO_STREAM_STATE_UNKNOWN;
    CHECK(AAudioStream_waitForStateChange(stream, AAUDIO_STREAM_STATE_STARTED, &next, 2000000000) == AAUDIO_OK);
    CHECK(next == AAUDIO_STREAM_STATE_STOPPED);
    usleep(400000);
    CHECK(AAudioStream_close(stream) == AAUDIO_OK);
    return check_output(ENOUGH);
}

static int test_aaudio_blocking(void) {
    AAudioStreamBuilder *builder = new_builder(AAUDIO_DIRECTION_OUTPUT);
    CHECK(builder != NULL);
    AAudioStream *stream = NULL;
    CHECK(AAudioStreamBuilder_openStream(builder, &stream) == AAUDIO_OK);
    AAudioStreamBuilder_delete(builder);
    CHECK(AAudioStream_requestStart(stream) == AAUDIO_OK);
    static int16_t samples[FRAMES * 4];
    fill_ramp(samples, FRAMES * 2, 1);
    CHECK(AAudioStream_write(stream, samples, FRAMES * 2, 5000000000) == FRAMES * 2);
    CHECK(AAudioStream_getFramesWritten(stream) == FRAMES * 2);
    usleep(400000);
    CHECK(AAudioStream_requestStop(stream) == AAUDIO_OK);
    CHECK(AAudioStream_getState(stream) == AAUDIO_STREAM_STATE_STOPPED);
    CHECK(AAudioStream_close(stream) == AAUDIO_OK);
    return check_output(ENOUGH);
}

static int test_aaudio_recording(void) {
    AAudioStreamBuilder *builder = new_builder(AAUDIO_DIRECTION_INPUT);
    CHECK(builder != NULL);
    AAudioStream *stream = NULL;
    CHECK(AAudioStreamBuilder_openStream(builder, &stream) == AAUDIO_OK);
    AAudioStreamBuilder_delete(builder);
    CHECK(AAudioStream_requestStart(stream) == AAUDIO_OK);
    static int16_t samples[RECORDED * 2];
    CHECK(AAudioStream_read(stream, samples, RECORDED, 5000000000) == RECORDED);
    for (int index = 0; index < RECORDED * 2; index++)
        CHECK(samples[index] == 0x4141);
    CHECK(AAudioStream_requestStop(stream) == AAUDIO_OK);
    CHECK(AAudioStream_close(stream) == AAUDIO_OK);
    CHECK(strcmp(AAudio_convertResultToText(AAUDIO_OK), "AAUDIO_OK") == 0);
    return 0;
}

int mead_selftest(void) {
    int (*const tests[])(void) = {
        test_opensles_playback, test_opensles_recording, test_aaudio_callback, test_aaudio_blocking, test_aaudio_recording,
    };
    for (size_t index = 0; index < sizeof(tests) / sizeof(tests[0]); index++) {
        int failed = tests[index]();
        if (failed)
            return failed;
    }
    return 0;
}
