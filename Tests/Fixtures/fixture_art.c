// A bionic JNI library for ART in Mead. Tests/ART/NativeCheck.java loads it
// with System.load, which goes through ART's bionic_dlopen to Mead's loader;
// ART then finds its natives both ways it can: by their exported names
// (Java_NativeCheck_add) and as JNI_OnLoad registers them (greet), and greet
// calls back into Java through ART's JNI.

#include <jni.h>
#include <stdio.h>
#include <string.h>

JNIEXPORT jint JNICALL Java_NativeCheck_add(JNIEnv *env, jclass type, jint left, jint right) {
    (void)env;
    (void)type;
    return left + right;
}

static jstring greet(JNIEnv *env, jclass type, jstring name) {
    jmethodID decorate = (*env)->GetStaticMethodID(env, type, "decorate", "(Ljava/lang/String;)Ljava/lang/String;");
    if (!decorate)
        return NULL;
    jstring decorated = (jstring)(*env)->CallStaticObjectMethod(env, type, decorate, name);
    if (!decorated || (*env)->ExceptionCheck(env))
        return NULL;
    const char *text = (*env)->GetStringUTFChars(env, decorated, NULL);
    char line[256];
    snprintf(line, sizeof(line), "%s, from bionic (%zu characters)", text, strlen(text));
    (*env)->ReleaseStringUTFChars(env, decorated, text);
    return (*env)->NewStringUTF(env, line);
}

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK)
        return JNI_ERR;
    jclass type = (*env)->FindClass(env, "NativeCheck");
    if (!type)
        return JNI_ERR;
    const JNINativeMethod methods[] = {
        { "greet", "(Ljava/lang/String;)Ljava/lang/String;", (void *)greet },
    };
    if ((*env)->RegisterNatives(env, type, methods, 1) != JNI_OK)
        return JNI_ERR;
    return JNI_VERSION_1_6;
}
