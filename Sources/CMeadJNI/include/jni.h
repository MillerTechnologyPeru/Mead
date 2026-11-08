#ifndef MEAD_JNI_ABI_H
#define MEAD_JNI_ABI_H

// The JNI ABI, for C, from the JNI 1.6 specification's types and function
// table order: the layout native code compiled against any jni.h expects.
// Scripts/check-jni-conformance.sh compares the order with the NDK's.

#include <stdarg.h>
#include <stdint.h>

typedef uint8_t jboolean;
typedef int8_t jbyte;
typedef uint16_t jchar;
typedef int16_t jshort;
typedef int32_t jint;
typedef int64_t jlong;
typedef float jfloat;
typedef double jdouble;
typedef jint jsize;

struct _jobject;
typedef struct _jobject *jobject;
typedef jobject jclass;
typedef jobject jstring;
typedef jobject jarray;
typedef jobject jobjectArray;
typedef jobject jthrowable;
typedef jobject jweak;

struct _jfieldID;
typedef struct _jfieldID *jfieldID;
struct _jmethodID;
typedef struct _jmethodID *jmethodID;

typedef union jvalue {
    jboolean z;
    jbyte b;
    jchar c;
    jshort s;
    jint i;
    jlong j;
    jfloat f;
    jdouble d;
    jobject l;
} jvalue;

typedef enum jobjectRefType {
    JNIInvalidRefType = 0,
    JNILocalRefType = 1,
    JNIGlobalRefType = 2,
    JNIWeakGlobalRefType = 3,
} jobjectRefType;

typedef struct JNINativeMethod {
    const char *name;
    const char *signature;
    void *fnPtr;
} JNINativeMethod;

typedef struct JavaVMAttachArgs {
    jint version;
    const char *name;
    jobject group;
} JavaVMAttachArgs;

struct JNINativeInterface;
struct JNIInvokeInterface;
typedef const struct JNINativeInterface *JNIEnv;
typedef const struct JNIInvokeInterface *JavaVM;

enum {
    JNI_FALSE = 0,
    JNI_TRUE = 1,
    JNI_VERSION_1_1 = 0x00010001,
    JNI_VERSION_1_2 = 0x00010002,
    JNI_VERSION_1_4 = 0x00010004,
    JNI_VERSION_1_6 = 0x00010006,
    JNI_OK = 0,
    JNI_ERR = -1,
    JNI_EDETACHED = -2,
    JNI_EVERSION = -3,
    JNI_COMMIT = 1,
    JNI_ABORT = 2,
};

#define MEAD_JNI_CALLS(prefix, Name, Type, ...)                                           \
    Type (*prefix##Name##Method)(JNIEnv *, __VA_ARGS__, jmethodID, ...);                  \
    Type (*prefix##Name##MethodV)(JNIEnv *, __VA_ARGS__, jmethodID, va_list);             \
    Type (*prefix##Name##MethodA)(JNIEnv *, __VA_ARGS__, jmethodID, const jvalue *);

#define MEAD_JNI_ALL_CALLS(prefix, ...)                                                   \
    MEAD_JNI_CALLS(prefix, Object, jobject, __VA_ARGS__)                                  \
    MEAD_JNI_CALLS(prefix, Boolean, jboolean, __VA_ARGS__)                                \
    MEAD_JNI_CALLS(prefix, Byte, jbyte, __VA_ARGS__)                                      \
    MEAD_JNI_CALLS(prefix, Char, jchar, __VA_ARGS__)                                      \
    MEAD_JNI_CALLS(prefix, Short, jshort, __VA_ARGS__)                                    \
    MEAD_JNI_CALLS(prefix, Int, jint, __VA_ARGS__)                                        \
    MEAD_JNI_CALLS(prefix, Long, jlong, __VA_ARGS__)                                      \
    MEAD_JNI_CALLS(prefix, Float, jfloat, __VA_ARGS__)                                    \
    MEAD_JNI_CALLS(prefix, Double, jdouble, __VA_ARGS__)                                  \
    MEAD_JNI_CALLS(prefix, Void, void, __VA_ARGS__)

#define MEAD_JNI_EACH_FIELD(M, ...)                                                       \
    M(__VA_ARGS__, Object, jobject)                                                       \
    M(__VA_ARGS__, Boolean, jboolean)                                                     \
    M(__VA_ARGS__, Byte, jbyte)                                                           \
    M(__VA_ARGS__, Char, jchar)                                                           \
    M(__VA_ARGS__, Short, jshort)                                                         \
    M(__VA_ARGS__, Int, jint)                                                             \
    M(__VA_ARGS__, Long, jlong)                                                           \
    M(__VA_ARGS__, Float, jfloat)                                                         \
    M(__VA_ARGS__, Double, jdouble)

#define MEAD_JNI_GETTER(prefix, Name, Type) Type (*Get##prefix##Name##Field)(JNIEnv *, jobject, jfieldID);
#define MEAD_JNI_SETTER(prefix, Name, Type) void (*Set##prefix##Name##Field)(JNIEnv *, jobject, jfieldID, Type);

#define MEAD_JNI_EACH_PRIMITIVE(M, ...)                                                   \
    M(__VA_ARGS__, Boolean, jboolean)                                                     \
    M(__VA_ARGS__, Byte, jbyte)                                                           \
    M(__VA_ARGS__, Char, jchar)                                                           \
    M(__VA_ARGS__, Short, jshort)                                                         \
    M(__VA_ARGS__, Int, jint)                                                             \
    M(__VA_ARGS__, Long, jlong)                                                           \
    M(__VA_ARGS__, Float, jfloat)                                                         \
    M(__VA_ARGS__, Double, jdouble)

#define MEAD_JNI_NEW_ARRAY(unused, Name, Type) jarray (*New##Name##Array)(JNIEnv *, jsize);
#define MEAD_JNI_GET_ELEMENTS(unused, Name, Type) Type *(*Get##Name##ArrayElements)(JNIEnv *, jarray, jboolean *);
#define MEAD_JNI_RELEASE_ELEMENTS(unused, Name, Type) void (*Release##Name##ArrayElements)(JNIEnv *, jarray, Type *, jint);
#define MEAD_JNI_GET_REGION(unused, Name, Type) void (*Get##Name##ArrayRegion)(JNIEnv *, jarray, jsize, jsize, Type *);
#define MEAD_JNI_SET_REGION(unused, Name, Type) void (*Set##Name##ArrayRegion)(JNIEnv *, jarray, jsize, jsize, const Type *);

struct JNINativeInterface {
    void *reserved0;
    void *reserved1;
    void *reserved2;
    void *reserved3;
    jint (*GetVersion)(JNIEnv *);
    jclass (*DefineClass)(JNIEnv *, const char *, jobject, const jbyte *, jsize);
    jclass (*FindClass)(JNIEnv *, const char *);
    jmethodID (*FromReflectedMethod)(JNIEnv *, jobject);
    jfieldID (*FromReflectedField)(JNIEnv *, jobject);
    jobject (*ToReflectedMethod)(JNIEnv *, jclass, jmethodID, jboolean);
    jclass (*GetSuperclass)(JNIEnv *, jclass);
    jboolean (*IsAssignableFrom)(JNIEnv *, jclass, jclass);
    jobject (*ToReflectedField)(JNIEnv *, jclass, jfieldID, jboolean);
    jint (*Throw)(JNIEnv *, jthrowable);
    jint (*ThrowNew)(JNIEnv *, jclass, const char *);
    jthrowable (*ExceptionOccurred)(JNIEnv *);
    void (*ExceptionDescribe)(JNIEnv *);
    void (*ExceptionClear)(JNIEnv *);
    void (*FatalError)(JNIEnv *, const char *);
    jint (*PushLocalFrame)(JNIEnv *, jint);
    jobject (*PopLocalFrame)(JNIEnv *, jobject);
    jobject (*NewGlobalRef)(JNIEnv *, jobject);
    void (*DeleteGlobalRef)(JNIEnv *, jobject);
    void (*DeleteLocalRef)(JNIEnv *, jobject);
    jboolean (*IsSameObject)(JNIEnv *, jobject, jobject);
    jobject (*NewLocalRef)(JNIEnv *, jobject);
    jint (*EnsureLocalCapacity)(JNIEnv *, jint);
    jobject (*AllocObject)(JNIEnv *, jclass);
    jobject (*NewObject)(JNIEnv *, jclass, jmethodID, ...);
    jobject (*NewObjectV)(JNIEnv *, jclass, jmethodID, va_list);
    jobject (*NewObjectA)(JNIEnv *, jclass, jmethodID, const jvalue *);
    jclass (*GetObjectClass)(JNIEnv *, jobject);
    jboolean (*IsInstanceOf)(JNIEnv *, jobject, jclass);
    jmethodID (*GetMethodID)(JNIEnv *, jclass, const char *, const char *);
    MEAD_JNI_ALL_CALLS(Call, jobject)
    MEAD_JNI_ALL_CALLS(CallNonvirtual, jobject, jclass)
    jfieldID (*GetFieldID)(JNIEnv *, jclass, const char *, const char *);
    MEAD_JNI_EACH_FIELD(MEAD_JNI_GETTER, )
    MEAD_JNI_EACH_FIELD(MEAD_JNI_SETTER, )
    jmethodID (*GetStaticMethodID)(JNIEnv *, jclass, const char *, const char *);
    MEAD_JNI_ALL_CALLS(CallStatic, jclass)
    jfieldID (*GetStaticFieldID)(JNIEnv *, jclass, const char *, const char *);
    MEAD_JNI_EACH_FIELD(MEAD_JNI_GETTER, Static)
    MEAD_JNI_EACH_FIELD(MEAD_JNI_SETTER, Static)
    jstring (*NewString)(JNIEnv *, const jchar *, jsize);
    jsize (*GetStringLength)(JNIEnv *, jstring);
    const jchar *(*GetStringChars)(JNIEnv *, jstring, jboolean *);
    void (*ReleaseStringChars)(JNIEnv *, jstring, const jchar *);
    jstring (*NewStringUTF)(JNIEnv *, const char *);
    jsize (*GetStringUTFLength)(JNIEnv *, jstring);
    const char *(*GetStringUTFChars)(JNIEnv *, jstring, jboolean *);
    void (*ReleaseStringUTFChars)(JNIEnv *, jstring, const char *);
    jsize (*GetArrayLength)(JNIEnv *, jarray);
    jobjectArray (*NewObjectArray)(JNIEnv *, jsize, jclass, jobject);
    jobject (*GetObjectArrayElement)(JNIEnv *, jobjectArray, jsize);
    void (*SetObjectArrayElement)(JNIEnv *, jobjectArray, jsize, jobject);
    MEAD_JNI_EACH_PRIMITIVE(MEAD_JNI_NEW_ARRAY, )
    MEAD_JNI_EACH_PRIMITIVE(MEAD_JNI_GET_ELEMENTS, )
    MEAD_JNI_EACH_PRIMITIVE(MEAD_JNI_RELEASE_ELEMENTS, )
    MEAD_JNI_EACH_PRIMITIVE(MEAD_JNI_GET_REGION, )
    MEAD_JNI_EACH_PRIMITIVE(MEAD_JNI_SET_REGION, )
    jint (*RegisterNatives)(JNIEnv *, jclass, const JNINativeMethod *, jint);
    jint (*UnregisterNatives)(JNIEnv *, jclass);
    jint (*MonitorEnter)(JNIEnv *, jobject);
    jint (*MonitorExit)(JNIEnv *, jobject);
    jint (*GetJavaVM)(JNIEnv *, JavaVM **);
    void (*GetStringRegion)(JNIEnv *, jstring, jsize, jsize, jchar *);
    void (*GetStringUTFRegion)(JNIEnv *, jstring, jsize, jsize, char *);
    void *(*GetPrimitiveArrayCritical)(JNIEnv *, jarray, jboolean *);
    void (*ReleasePrimitiveArrayCritical)(JNIEnv *, jarray, void *, jint);
    const jchar *(*GetStringCritical)(JNIEnv *, jstring, jboolean *);
    void (*ReleaseStringCritical)(JNIEnv *, jstring, const jchar *);
    jweak (*NewWeakGlobalRef)(JNIEnv *, jobject);
    void (*DeleteWeakGlobalRef)(JNIEnv *, jweak);
    jboolean (*ExceptionCheck)(JNIEnv *);
    jobject (*NewDirectByteBuffer)(JNIEnv *, void *, jlong);
    void *(*GetDirectBufferAddress)(JNIEnv *, jobject);
    jlong (*GetDirectBufferCapacity)(JNIEnv *, jobject);
    jobjectRefType (*GetObjectRefType)(JNIEnv *, jobject);
};

struct JNIInvokeInterface {
    void *reserved0;
    void *reserved1;
    void *reserved2;
    jint (*DestroyJavaVM)(JavaVM *);
    jint (*AttachCurrentThread)(JavaVM *, JNIEnv **, void *);
    jint (*DetachCurrentThread)(JavaVM *);
    jint (*GetEnv)(JavaVM *, void **, jint);
    jint (*AttachCurrentThreadAsDaemon)(JavaVM *, JNIEnv **, void *);
};

#endif
