#ifndef MEAD_ANDROID_H
#define MEAD_ANDROID_H

// libandroid.so's public structures, in the NDK's layout (compared with the
// NDK's headers by Scripts/check-android-abi.sh), and the bits of the host
// that are awkward from Swift.

#include "jni.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct ANativeActivity;

typedef struct ANativeActivityCallbacks {
    void (*onStart)(struct ANativeActivity *);
    void (*onResume)(struct ANativeActivity *);
    void *(*onSaveInstanceState)(struct ANativeActivity *, size_t *);
    void (*onPause)(struct ANativeActivity *);
    void (*onStop)(struct ANativeActivity *);
    void (*onDestroy)(struct ANativeActivity *);
    void (*onWindowFocusChanged)(struct ANativeActivity *, int);
    void (*onNativeWindowCreated)(struct ANativeActivity *, void *);
    void (*onNativeWindowResized)(struct ANativeActivity *, void *);
    void (*onNativeWindowRedrawNeeded)(struct ANativeActivity *, void *);
    void (*onNativeWindowDestroyed)(struct ANativeActivity *, void *);
    void (*onInputQueueCreated)(struct ANativeActivity *, void *);
    void (*onInputQueueDestroyed)(struct ANativeActivity *, void *);
    void (*onContentRectChanged)(struct ANativeActivity *, const void *);
    void (*onConfigurationChanged)(struct ANativeActivity *);
    void (*onLowMemory)(struct ANativeActivity *);
} ANativeActivityCallbacks;

typedef struct ANativeActivity {
    ANativeActivityCallbacks *callbacks;
    JavaVM *vm;
    JNIEnv *env;
    jobject clazz;
    const char *internalDataPath;
    const char *externalDataPath;
    int32_t sdkVersion;
    void *instance;
    void *assetManager;
    const char *obbPath;
} ANativeActivity;

typedef void (*mead_activity_on_create)(ANativeActivity *, void *, size_t);

// epoll, in ALooper's own vocabulary of events.
typedef struct mead_poll_item {
    int fd;
    int events;
} mead_poll_item;

enum {
    MEAD_LOOPER_EVENT_INPUT = 1,
    MEAD_LOOPER_EVENT_OUTPUT = 2,
    MEAD_LOOPER_EVENT_ERROR = 4,
    MEAD_LOOPER_EVENT_HANGUP = 8,
};

int mead_poll_create(void);
int mead_poll_add(int poll_fd, int fd, int events);
int mead_poll_modify(int poll_fd, int fd, int events);
int mead_poll_remove(int poll_fd, int fd);
int mead_poll_wait(int poll_fd, mead_poll_item *items, int capacity, int timeout);

// A counter that is readable while it is above zero.
int mead_event_create(void);
void mead_event_signal(int fd);
void mead_event_drain(int fd);

// The next regular file in a directory, skipping everything else; NULL at
// the end.
const char *mead_next_file_name(void *directory);

#endif
