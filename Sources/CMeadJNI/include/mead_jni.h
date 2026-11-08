#ifndef MEAD_JNI_H
#define MEAD_JNI_H

// The boundary between the JNI function tables, in C, and the runtime behind
// them, in Swift. The ninety Call* entries, the seventy-two typed field
// accessors and the array families all come down to the handful of generic
// functions here: only C can write variadics, and only macros are short
// enough to write the families out.

#include "jni.h"

#include <stddef.h>

// What a JNIEnv * points at: the function table, as JNI requires, and then
// the thread it belongs to.
typedef struct mead_jni_env_block {
    const struct JNINativeInterface *functions;
    void *thread;
} mead_jni_env_block;

const struct JNINativeInterface *mead_jni_function_table(void);
const struct JNIInvokeInterface *mead_jni_invoke_table(void);

// Calls a native function with a method's arguments on the arm64 calling
// convention. `shorty` is the return type's letter then each argument's.
void mead_jni_call_native(void *function, JNIEnv *env, jobject receiver, const char *shorty,
                          const jvalue *arguments, jvalue *result);

enum { MEAD_JNI_VIRTUAL = 0, MEAD_JNI_NONVIRTUAL = 1, MEAD_JNI_STATIC = 2 };

// Implemented in Swift.
const char *mead_jni_method_shorty(jmethodID method);
void mead_jni_invoke(JNIEnv *env, int mode, jobject target, jmethodID method, const jvalue *arguments, jvalue *result);
jobject mead_jni_new_object(JNIEnv *env, jclass type, jmethodID method, const jvalue *arguments);
void mead_jni_get_field(JNIEnv *env, jobject target, jfieldID field, jvalue *result);
void mead_jni_set_field(JNIEnv *env, jobject target, jfieldID field, const jvalue *value);
jarray mead_jni_new_array(JNIEnv *env, char kind, jsize length);
void *mead_jni_array_elements(JNIEnv *env, jarray array, jboolean *is_copy);
void mead_jni_array_release(JNIEnv *env, jarray array, void *elements, jint mode);
void mead_jni_array_region(JNIEnv *env, jarray array, jsize start, jsize length, void *buffer, jboolean write);

jint mead_jni_GetVersion(JNIEnv *);
jclass mead_jni_DefineClass(JNIEnv *, const char *, jobject, const jbyte *, jsize);
jclass mead_jni_FindClass(JNIEnv *, const char *);
jmethodID mead_jni_FromReflectedMethod(JNIEnv *, jobject);
jfieldID mead_jni_FromReflectedField(JNIEnv *, jobject);
jobject mead_jni_ToReflectedMethod(JNIEnv *, jclass, jmethodID, jboolean);
jclass mead_jni_GetSuperclass(JNIEnv *, jclass);
jboolean mead_jni_IsAssignableFrom(JNIEnv *, jclass, jclass);
jobject mead_jni_ToReflectedField(JNIEnv *, jclass, jfieldID, jboolean);
jint mead_jni_Throw(JNIEnv *, jthrowable);
jint mead_jni_ThrowNew(JNIEnv *, jclass, const char *);
jthrowable mead_jni_ExceptionOccurred(JNIEnv *);
void mead_jni_ExceptionDescribe(JNIEnv *);
void mead_jni_ExceptionClear(JNIEnv *);
void mead_jni_FatalError(JNIEnv *, const char *);
jint mead_jni_PushLocalFrame(JNIEnv *, jint);
jobject mead_jni_PopLocalFrame(JNIEnv *, jobject);
jobject mead_jni_NewGlobalRef(JNIEnv *, jobject);
void mead_jni_DeleteGlobalRef(JNIEnv *, jobject);
void mead_jni_DeleteLocalRef(JNIEnv *, jobject);
jboolean mead_jni_IsSameObject(JNIEnv *, jobject, jobject);
jobject mead_jni_NewLocalRef(JNIEnv *, jobject);
jint mead_jni_EnsureLocalCapacity(JNIEnv *, jint);
jobject mead_jni_AllocObject(JNIEnv *, jclass);
jclass mead_jni_GetObjectClass(JNIEnv *, jobject);
jboolean mead_jni_IsInstanceOf(JNIEnv *, jobject, jclass);
jmethodID mead_jni_GetMethodID(JNIEnv *, jclass, const char *, const char *);
jfieldID mead_jni_GetFieldID(JNIEnv *, jclass, const char *, const char *);
jmethodID mead_jni_GetStaticMethodID(JNIEnv *, jclass, const char *, const char *);
jfieldID mead_jni_GetStaticFieldID(JNIEnv *, jclass, const char *, const char *);
jstring mead_jni_NewString(JNIEnv *, const jchar *, jsize);
jsize mead_jni_GetStringLength(JNIEnv *, jstring);
const jchar *mead_jni_GetStringChars(JNIEnv *, jstring, jboolean *);
void mead_jni_ReleaseStringChars(JNIEnv *, jstring, const jchar *);
jstring mead_jni_NewStringUTF(JNIEnv *, const char *);
jsize mead_jni_GetStringUTFLength(JNIEnv *, jstring);
const char *mead_jni_GetStringUTFChars(JNIEnv *, jstring, jboolean *);
void mead_jni_ReleaseStringUTFChars(JNIEnv *, jstring, const char *);
jsize mead_jni_GetArrayLength(JNIEnv *, jarray);
jobjectArray mead_jni_NewObjectArray(JNIEnv *, jsize, jclass, jobject);
jobject mead_jni_GetObjectArrayElement(JNIEnv *, jobjectArray, jsize);
void mead_jni_SetObjectArrayElement(JNIEnv *, jobjectArray, jsize, jobject);
jint mead_jni_RegisterNatives(JNIEnv *, jclass, const JNINativeMethod *, jint);
jint mead_jni_UnregisterNatives(JNIEnv *, jclass);
jint mead_jni_MonitorEnter(JNIEnv *, jobject);
jint mead_jni_MonitorExit(JNIEnv *, jobject);
jint mead_jni_GetJavaVM(JNIEnv *, JavaVM **);
void mead_jni_GetStringRegion(JNIEnv *, jstring, jsize, jsize, jchar *);
void mead_jni_GetStringUTFRegion(JNIEnv *, jstring, jsize, jsize, char *);
const jchar *mead_jni_GetStringCritical(JNIEnv *, jstring, jboolean *);
void mead_jni_ReleaseStringCritical(JNIEnv *, jstring, const jchar *);
jweak mead_jni_NewWeakGlobalRef(JNIEnv *, jobject);
void mead_jni_DeleteWeakGlobalRef(JNIEnv *, jweak);
jboolean mead_jni_ExceptionCheck(JNIEnv *);
jobject mead_jni_NewDirectByteBuffer(JNIEnv *, void *, jlong);
void *mead_jni_GetDirectBufferAddress(JNIEnv *, jobject);
jlong mead_jni_GetDirectBufferCapacity(JNIEnv *, jobject);
jobjectRefType mead_jni_GetObjectRefType(JNIEnv *, jobject);

jint mead_jni_DestroyJavaVM(JavaVM *);
jint mead_jni_AttachCurrentThread(JavaVM *, JNIEnv **, void *);
jint mead_jni_DetachCurrentThread(JavaVM *);
jint mead_jni_GetEnv(JavaVM *, void **, jint);
jint mead_jni_AttachCurrentThreadAsDaemon(JavaVM *, JNIEnv **, void *);

#endif
