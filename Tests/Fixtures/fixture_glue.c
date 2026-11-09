// A real NativeActivity app, on the NDK's own android_native_app_glue. It
// waits for its window, receives input that went through SDL, reads assets,
// uses the Java framework classes, and finishes. Any failure ends the
// process with a nonzero status; only success gets as far as finishing.

#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <android/configuration.h>
#include <android/input.h>
#include <android/log.h>
#include <android/looper.h>
#include <android/native_window.h>
#include <android_native_app_glue.h>
#include <dlfcn.h>
#include <jni.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "fixture_glue", __VA_ARGS__)

#define CHECK(condition)                                                                   \
    do {                                                                                   \
        if (!(condition)) {                                                                \
            fprintf(stderr, "fixture_glue: line %d: %s\n", __LINE__, #condition);          \
            _exit(2);                                                                      \
        }                                                                                  \
    } while (0)

void mead_android_inject_key(uint32_t scancode, bool down);
void mead_android_inject_touch(float x, float y, bool down);

enum { SCANCODE_A = 4, KEYCODE_A = 29 };

static bool window_ready, saw_key, saw_touch, finished;

static void test_assets(struct android_app *app) {
    AAssetManager *manager = app->activity->assetManager;
    AAsset *asset = AAssetManager_open(manager, "hello.txt", AASSET_MODE_BUFFER);
    CHECK(asset != NULL);
    CHECK(AAsset_getLength(asset) == 17);
    CHECK(AAsset_getLength64(asset) == 17);
    char text[32] = { 0 };
    CHECK(AAsset_read(asset, text, 5) == 5);
    CHECK(strcmp(text, "hello") == 0);
    CHECK(AAsset_getRemainingLength(asset) == 12);
    CHECK(AAsset_seek(asset, 6, SEEK_SET) == 6);
    CHECK(AAsset_read(asset, text, 4) == 4);
    CHECK(memcmp(text, "from", 4) == 0);
    const void *buffer = AAsset_getBuffer(asset);
    CHECK(buffer != NULL && memcmp(buffer, "hello from assets", 17) == 0);
    AAsset_close(asset);

    asset = AAssetManager_open(manager, "sub/nested.txt", AASSET_MODE_STREAMING);
    CHECK(asset != NULL && AAsset_getLength(asset) == 6);
    AAsset_close(asset);
    CHECK(AAssetManager_open(manager, "missing.txt", AASSET_MODE_BUFFER) == NULL);
    CHECK(AAssetManager_open(manager, "../hello.txt", AASSET_MODE_BUFFER) == NULL);

    AAssetDir *directory = AAssetManager_openDir(manager, "");
    CHECK(directory != NULL);
    bool found = false;
    for (const char *name; (name = AAssetDir_getNextFileName(directory));) {
        CHECK(strcmp(name, "sub") != 0); // files only, as on Android
        found = found || strcmp(name, "hello.txt") == 0;
    }
    CHECK(found);
    AAssetDir_close(directory);
}

JNIEXPORT jint JNICALL Java_com_mead_fixture_Bound_add(JNIEnv *env, jclass type, jint a, jint b) {
    (void)env, (void)type;
    return a + b;
}

JNIEXPORT jint JNICALL Java_com_mead_fixture_Bound_twice__I(JNIEnv *env, jclass type, jint value) {
    (void)env, (void)type;
    return value * 2;
}

JNIEXPORT jstring JNICALL Java_com_mead_fixture_Under_1score_echo__Ljava_lang_String_2(JNIEnv *env, jclass type, jstring text) {
    (void)env, (void)type;
    return text;
}

#define E(function, ...) (*env)->function(env, __VA_ARGS__)
#define E0(function) (*env)->function(env)

static void test_java(struct android_app *app) {
    JavaVM *vm = app->activity->vm;
    JNIEnv *env = NULL;
    CHECK((*vm)->AttachCurrentThread(vm, &env, NULL) == JNI_OK);
    jobject activity = app->activity->clazz;

    jclass native_activity = E(FindClass, "android/app/NativeActivity");
    jclass context = E(FindClass, "android/content/Context");
    CHECK(E(IsInstanceOf, activity, native_activity));
    CHECK(E(IsInstanceOf, activity, context));

    jmethodID get_assets = E(GetMethodID, context, "getAssets", "()Landroid/content/res/AssetManager;");
    jobject assets = (*env)->CallObjectMethod(env, activity, get_assets);
    CHECK(assets != NULL);
    CHECK(AAssetManager_fromJava(env, assets) == app->activity->assetManager);

    jmethodID get_package = E(GetMethodID, context, "getPackageName", "()Ljava/lang/String;");
    jstring package = (*env)->CallObjectMethod(env, activity, get_package);
    CHECK(package != NULL && E(GetStringUTFLength, package) > 0);

    jclass version = E(FindClass, "android/os/Build$VERSION");
    jfieldID sdk = E(GetStaticFieldID, version, "SDK_INT", "I");
    CHECK(E(GetStaticIntField, version, sdk) == app->activity->sdkVersion);
    CHECK(app->activity->sdkVersion >= 21);
    jclass build = E(FindClass, "android/os/Build");
    jfieldID model = E(GetStaticFieldID, build, "MODEL", "Ljava/lang/String;");
    CHECK(E(GetStaticObjectField, build, model) != NULL);

    // A call through an interface reaches the class's own method.
    jclass list_class = E(FindClass, "java/util/List");
    jclass array_list = E(FindClass, "java/util/ArrayList");
    jmethodID make = E(GetMethodID, array_list, "<init>", "()V");
    jobject list = (*env)->NewObject(env, array_list, make);
    CHECK(list != NULL && E(IsInstanceOf, list, list_class));
    CHECK(E(IsAssignableFrom, array_list, list_class));
    jstring item = E(NewStringUTF, "item");
    jmethodID add = E(GetMethodID, list_class, "add", "(Ljava/lang/Object;)Z");
    CHECK((*env)->CallBooleanMethod(env, list, add, item));
    jmethodID size = E(GetMethodID, list_class, "size", "()I");
    CHECK((*env)->CallIntMethod(env, list, size) == 1);
    jmethodID get = E(GetMethodID, list_class, "get", "(I)Ljava/lang/Object;");
    jobject got = (*env)->CallObjectMethod(env, list, get, 0);
    CHECK(E(IsSameObject, got, item));
    (void)(*env)->CallObjectMethod(env, list, get, 5);
    CHECK(E0(ExceptionCheck));
    E0(ExceptionClear);

    // Keys compare by value, not by being the same object.
    jclass hash_map = E(FindClass, "java/util/HashMap");
    jobject map = (*env)->NewObject(env, hash_map, E(GetMethodID, hash_map, "<init>", "()V"));
    jmethodID put = E(GetMethodID, hash_map, "put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;");
    jmethodID lookup = E(GetMethodID, hash_map, "get", "(Ljava/lang/Object;)Ljava/lang/Object;");
    (void)(*env)->CallObjectMethod(env, map, put, E(NewStringUTF, "key"), item);
    got = (*env)->CallObjectMethod(env, map, lookup, E(NewStringUTF, "key"));
    CHECK(E(IsSameObject, got, item));

    jclass uuid = E(FindClass, "java/util/UUID");
    jobject random = (*env)->CallStaticObjectMethod(env, uuid, E(GetStaticMethodID, uuid, "randomUUID", "()Ljava/util/UUID;"));
    jstring uuid_text = (*env)->CallObjectMethod(env, random, E(GetMethodID, uuid, "toString", "()Ljava/lang/String;"));
    CHECK(E(GetStringLength, uuid_text) == 36);

    jclass integer = E(FindClass, "java/lang/Integer");
    jobject boxed = (*env)->CallStaticObjectMethod(env, integer, E(GetStaticMethodID, integer, "valueOf", "(I)Ljava/lang/Integer;"), 41);
    CHECK((*env)->CallIntMethod(env, boxed, E(GetMethodID, integer, "intValue", "()I")) == 41);

    // System.loadLibrary finds a library by name and runs its JNI_OnLoad.
    jclass system = E(FindClass, "java/lang/System");
    jmethodID load = E(GetStaticMethodID, system, "loadLibrary", "(Ljava/lang/String;)V");
    (*env)->CallStaticVoidMethod(env, system, load, E(NewStringUTF, "fixture_android_lib"));
    CHECK(!E0(ExceptionCheck));
    int *loaded = dlsym(RTLD_DEFAULT, "fixture_android_lib_loaded");
    CHECK(loaded != NULL && *loaded == 1);
    (*env)->CallStaticVoidMethod(env, system, load, E(NewStringUTF, "fixture_no_such_library"));
    CHECK(E0(ExceptionCheck));
    E0(ExceptionClear);

    // Natives nothing registered, found by JNI's naming rule.
    jclass bound = E(FindClass, "com/mead/fixture/Bound");
    jmethodID sum = E(GetStaticMethodID, bound, "add", "(II)I");
    CHECK((*env)->CallStaticIntMethod(env, bound, sum, 40, 2) == 42);
    jmethodID twice = E(GetStaticMethodID, bound, "twice", "(I)I");
    CHECK((*env)->CallStaticIntMethod(env, bound, twice, 21) == 42);
    jclass under = E(FindClass, "com/mead/fixture/Under_score");
    jmethodID echo = E(GetStaticMethodID, under, "echo", "(Ljava/lang/String;)Ljava/lang/String;");
    jstring echoed = (*env)->CallStaticObjectMethod(env, under, echo, item);
    CHECK(E(IsSameObject, echoed, item));

    CHECK((*vm)->DetachCurrentThread(vm) == JNI_OK);
}

static void test_configuration(struct android_app *app) {
    char language[2];
    AConfiguration_getLanguage(app->config, language);
    CHECK(language[0] == 'e' && language[1] == 'n');
    CHECK(AConfiguration_getSdkVersion(app->config) >= 21);
}

static void maybe_finish(struct android_app *app) {
    if (finished || !saw_key || !saw_touch)
        return;
    finished = true;
    test_assets(app);
    test_configuration(app);
    test_java(app);
    LOG("every check passed");
    ANativeActivity_finish(app->activity);
}

static void on_command(struct android_app *app, int32_t command) {
    if (command != APP_CMD_INIT_WINDOW)
        return;
    CHECK(app->window != NULL);
    CHECK(ANativeWindow_getWidth(app->window) == 1280);
    CHECK(ANativeWindow_getHeight(app->window) == 720);
    CHECK(ANativeWindow_setBuffersGeometry(app->window, 640, 360, 0) == 0);
    CHECK(ANativeWindow_getWidth(app->window) == 640);
    window_ready = true;
    mead_android_inject_key(SCANCODE_A, true);
    mead_android_inject_touch(100.0f, 50.0f, true);
}

static int32_t on_input(struct android_app *app, AInputEvent *event) {
    CHECK(window_ready);
    if (AInputEvent_getType(event) == AINPUT_EVENT_TYPE_KEY) {
        CHECK(AKeyEvent_getKeyCode(event) == KEYCODE_A);
        CHECK(AKeyEvent_getAction(event) == AKEY_EVENT_ACTION_DOWN);
        saw_key = true;
    } else if (AInputEvent_getType(event) == AINPUT_EVENT_TYPE_MOTION) {
        CHECK(AMotionEvent_getPointerCount(event) == 1);
        CHECK(AMotionEvent_getAction(event) == AMOTION_EVENT_ACTION_DOWN);
        CHECK(AMotionEvent_getX(event, 0) == 100.0f && AMotionEvent_getY(event, 0) == 50.0f);
        saw_touch = true;
    }
    maybe_finish(app);
    return 1;
}

void android_main(struct android_app *app) {
    app->onAppCmd = on_command;
    app->onInputEvent = on_input;
    while (!app->destroyRequested) {
        struct android_poll_source *source = NULL;
        int ident = ALooper_pollOnce(-1, NULL, NULL, (void **)&source);
        if (ident >= 0 && source != NULL)
            source->process(app, source);
    }
    CHECK(finished);
}
