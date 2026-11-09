// What a game loads with System.loadLibrary: JNI_OnLoad is the proof.

#include <jni.h>

int fixture_android_lib_loaded = 0;

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) == JNI_OK && env != NULL)
        fixture_android_lib_loaded = 1;
    return JNI_VERSION_1_6;
}
