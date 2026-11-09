#ifndef MEAD_OPENSLES_H
#define MEAD_OPENSLES_H

// OpenSL ES's ABI as far as Android apps use it: result codes, the structures
// describing audio, and the interface tables. Scripts/check-android-abi.sh
// holds the tables' order to the NDK's headers. A table's entries are
// declared without their parameters, which only the code behind each needs.

#include "mead_interface.h"

#include <stdint.h>

typedef uint32_t SLresult;
typedef uint32_t SLuint32;
typedef int16_t SLmillibel;

enum {
    SL_RESULT_SUCCESS = 0,
    SL_RESULT_PRECONDITIONS_VIOLATED = 1,
    SL_RESULT_PARAMETER_INVALID = 2,
    SL_RESULT_MEMORY_FAILURE = 3,
    SL_RESULT_RESOURCE_ERROR = 4,
    SL_RESULT_BUFFER_INSUFFICIENT = 7,
    SL_RESULT_CONTENT_UNSUPPORTED = 9,
    SL_RESULT_FEATURE_UNSUPPORTED = 12,

    SL_OBJECT_STATE_UNREALIZED = 1,
    SL_OBJECT_STATE_REALIZED = 2,

    SL_PLAYSTATE_STOPPED = 1,
    SL_PLAYSTATE_PAUSED = 2,
    SL_PLAYSTATE_PLAYING = 3,
    SL_RECORDSTATE_STOPPED = 1,
    SL_RECORDSTATE_PAUSED = 2,
    SL_RECORDSTATE_RECORDING = 3,

    SL_DATAFORMAT_PCM = 2,
    SL_ANDROID_DATAFORMAT_PCM_EX = 4,
    SL_ANDROID_PCM_REPRESENTATION_FLOAT = 3,
};

typedef const void *SLInterfaceID;

#define SL_METHOD(name) SLresult (*name)()

struct SLObjectItf_ {
    SL_METHOD(Realize);
    SL_METHOD(Resume);
    SL_METHOD(GetState);
    SL_METHOD(GetInterface);
    SL_METHOD(RegisterCallback);
    void (*AbortAsyncOperation)();
    void (*Destroy)();
    SL_METHOD(SetPriority);
    SL_METHOD(GetPriority);
    SL_METHOD(SetLossOfControlInterfaces);
};

struct SLEngineItf_ {
    SL_METHOD(CreateLEDDevice);
    SL_METHOD(CreateVibraDevice);
    SL_METHOD(CreateAudioPlayer);
    SL_METHOD(CreateAudioRecorder);
    SL_METHOD(CreateMidiPlayer);
    SL_METHOD(CreateListener);
    SL_METHOD(Create3DGroup);
    SL_METHOD(CreateOutputMix);
    SL_METHOD(CreateMetadataExtractor);
    SL_METHOD(CreateExtensionObject);
    SL_METHOD(QueryNumSupportedInterfaces);
    SL_METHOD(QuerySupportedInterfaces);
    SL_METHOD(QueryNumSupportedExtensions);
    SL_METHOD(QuerySupportedExtension);
    SL_METHOD(IsExtensionSupported);
};

struct SLPlayItf_ {
    SL_METHOD(SetPlayState);
    SL_METHOD(GetPlayState);
    SL_METHOD(GetDuration);
    SL_METHOD(GetPosition);
    SL_METHOD(RegisterCallback);
    SL_METHOD(SetCallbackEventsMask);
    SL_METHOD(GetCallbackEventsMask);
    SL_METHOD(SetMarkerPosition);
    SL_METHOD(ClearMarkerPosition);
    SL_METHOD(GetMarkerPosition);
    SL_METHOD(SetPositionUpdatePeriod);
    SL_METHOD(GetPositionUpdatePeriod);
};

struct SLRecordItf_ {
    SL_METHOD(SetRecordState);
    SL_METHOD(GetRecordState);
    SL_METHOD(SetDurationLimit);
    SL_METHOD(GetPosition);
    SL_METHOD(RegisterCallback);
    SL_METHOD(SetCallbackEventsMask);
    SL_METHOD(GetCallbackEventsMask);
    SL_METHOD(SetMarkerPosition);
    SL_METHOD(ClearMarkerPosition);
    SL_METHOD(GetMarkerPosition);
    SL_METHOD(SetPositionUpdatePeriod);
    SL_METHOD(GetPositionUpdatePeriod);
};

struct SLVolumeItf_ {
    SL_METHOD(SetVolumeLevel);
    SL_METHOD(GetVolumeLevel);
    SL_METHOD(GetMaxVolumeLevel);
    SL_METHOD(SetMute);
    SL_METHOD(GetMute);
    SL_METHOD(EnableStereoPosition);
    SL_METHOD(IsEnabledStereoPosition);
    SL_METHOD(SetStereoPosition);
    SL_METHOD(GetStereoPosition);
};

struct SLBufferQueueItf_ {
    SL_METHOD(Enqueue);
    SL_METHOD(Clear);
    SL_METHOD(GetState);
    SL_METHOD(RegisterCallback);
};

struct SLAndroidSimpleBufferQueueItf_ {
    SL_METHOD(Enqueue);
    SL_METHOD(Clear);
    SL_METHOD(GetState);
    SL_METHOD(RegisterCallback);
};

struct SLAndroidConfigurationItf_ {
    SL_METHOD(SetConfiguration);
    SL_METHOD(GetConfiguration);
    SL_METHOD(AcquireJavaProxy);
    SL_METHOD(ReleaseJavaProxy);
};

typedef struct SLDataLocator_BufferQueue {
    SLuint32 locatorType;
    SLuint32 numBuffers;
} SLDataLocator_BufferQueue;

typedef struct SLDataFormat_PCM {
    SLuint32 formatType;
    SLuint32 numChannels;
    SLuint32 samplesPerSec; // in millihertz
    SLuint32 bitsPerSample;
    SLuint32 containerSize;
    SLuint32 channelMask;
    SLuint32 endianness;
} SLDataFormat_PCM;

typedef struct SLAndroidDataFormat_PCM_EX {
    SLuint32 formatType;
    SLuint32 numChannels;
    SLuint32 sampleRate;
    SLuint32 bitsPerSample;
    SLuint32 containerSize;
    SLuint32 channelMask;
    SLuint32 endianness;
    SLuint32 representation;
} SLAndroidDataFormat_PCM_EX;

typedef struct SLDataSource {
    void *pLocator;
    void *pFormat;
} SLDataSource;

typedef SLDataSource SLDataSink;

#endif
