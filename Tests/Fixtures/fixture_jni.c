// mead --selftest's JNI conformance suite: every JNIEnv and JavaVM entry,
// compiled against the NDK's jni.h, so that the function table's layout is
// tested as a game would test it. Scripts/check-jni-conformance.sh checks
// that nothing has been left out. Returns the line of the first failure.

#include <jni.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition)                                                                   \
    do {                                                                                   \
        if (!(condition)) {                                                                \
            fprintf(stderr, "fixture_jni: line %d: %s\n", __LINE__, #condition);           \
            return __LINE__;                                                               \
        }                                                                                  \
    } while (0)

#define E(function, ...) (*env)->function(env, __VA_ARGS__)
#define E0(function) (*env)->function(env)
#define NO_EXCEPTION() CHECK(!E0(ExceptionCheck))

static const char *const SUBJECT = "com/mead/fixture/Subject";

// The arguments every native is called with, to prove they arrive intact.
#define ARG_I 123456
#define ARG_J 0x123456789abLL
#define ARG_F 3.5f
#define ARG_D -7.25
#define ARGS_SIGNATURE "(IJFDLjava/lang/String;)"

static int native_calls;
static int bad_arguments;
static jstring expected_string;

static void check_arguments(JNIEnv *env, jint i, jlong j, jfloat f, jdouble d, jstring s) {
    native_calls++;
    if (i != ARG_I || j != ARG_J || f != ARG_F || d != ARG_D || !E(IsSameObject, s, expected_string))
        bad_arguments++;
}

#define EACH_RETURNING(M)                                                                  \
    M(Object, jobject, "Ljava/lang/String;", s)                                            \
    M(Boolean, jboolean, "Z", JNI_TRUE)                                                    \
    M(Byte, jbyte, "B", -5)                                                                \
    M(Char, jchar, "C", 0x2603)                                                            \
    M(Short, jshort, "S", -300)                                                            \
    M(Int, jint, "I", 70000)                                                               \
    M(Long, jlong, "J", 1LL << 40)                                                         \
    M(Float, jfloat, "F", 1.5f)                                                            \
    M(Double, jdouble, "D", 2.25)

#define DEFINE_NATIVE(Name, Type, descriptor, value)                                       \
    static Type JNICALL native_##Name(JNIEnv *env, jobject self, jint i, jlong j, jfloat f, \
                                      jdouble d, jstring s) {                              \
        (void)self;                                                                        \
        check_arguments(env, i, j, f, d, s);                                               \
        return value;                                                                      \
    }
EACH_RETURNING(DEFINE_NATIVE)

static void JNICALL native_Void(JNIEnv *env, jobject self, jint i, jlong j, jfloat f, jdouble d, jstring s) {
    (void)self;
    check_arguments(env, i, j, f, d, s);
}

static jint constructed_with;

static void JNICALL native_init(JNIEnv *env, jobject self, jint value) {
    (void)env, (void)self;
    constructed_with = value;
}

// More arguments than registers: the rest are on the stack.
static jlong JNICALL native_many(JNIEnv *env, jobject self, jint a, jint b, jint c, jint d, jint e, jint f,
                                 jint g, jint h, jfloat p, jfloat q, jdouble r, jdouble s, jdouble t,
                                 jdouble u, jdouble v, jdouble w, jdouble x, jbyte y, jshort z) {
    (void)env, (void)self;
    return a + 2LL * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h + (jlong)(p + q + r + s + t + u + v + w + x) + y + z;
}

#define NATIVE_ENTRIES(Name, Type, descriptor, value)                                      \
    { "call" #Name, ARGS_SIGNATURE descriptor, (void *)native_##Name },                    \
    { "static" #Name, ARGS_SIGNATURE descriptor, (void *)native_##Name },

static const JNINativeMethod natives[] = {
    EACH_RETURNING(NATIVE_ENTRIES)
    { "callVoid", ARGS_SIGNATURE "V", (void *)native_Void },
    { "staticVoid", ARGS_SIGNATURE "V", (void *)native_Void },
    { "<init>", "(I)V", (void *)native_init },
    { "many", "(IIIIIIIIFFDDDDDDDBS)J", (void *)native_many },
};

#define matches_Object(got) E(IsSameObject, got, expected_string)
#define matches_Boolean(got) ((got) == JNI_TRUE)
#define matches_Byte(got) ((got) == -5)
#define matches_Char(got) ((got) == 0x2603)
#define matches_Short(got) ((got) == -300)
#define matches_Int(got) ((got) == 70000)
#define matches_Long(got) ((got) == 1LL << 40)
#define matches_Float(got) ((got) == 1.5f)
#define matches_Double(got) ((got) == 2.25)

// The va_list forms need a function with a variable argument list to get one.
#define DEFINE_V(Name, Type, descriptor, value)                                            \
    static Type virtual_v_##Name(JNIEnv *env, jobject o, jmethodID m, ...) {               \
        va_list l;                                                                         \
        va_start(l, m);                                                                    \
        Type r = (*env)->Call##Name##MethodV(env, o, m, l);                                \
        va_end(l);                                                                         \
        return r;                                                                          \
    }                                                                                      \
    static Type nonvirtual_v_##Name(JNIEnv *env, jobject o, jclass c, jmethodID m, ...) {  \
        va_list l;                                                                         \
        va_start(l, m);                                                                    \
        Type r = (*env)->CallNonvirtual##Name##MethodV(env, o, c, m, l);                   \
        va_end(l);                                                                         \
        return r;                                                                          \
    }                                                                                      \
    static Type static_v_##Name(JNIEnv *env, jclass c, jmethodID m, ...) {                 \
        va_list l;                                                                         \
        va_start(l, m);                                                                    \
        Type r = (*env)->CallStatic##Name##MethodV(env, c, m, l);                          \
        va_end(l);                                                                         \
        return r;                                                                          \
    }
EACH_RETURNING(DEFINE_V)

static void virtual_v_Void(JNIEnv *env, jobject o, jmethodID m, ...) {
    va_list l;
    va_start(l, m);
    (*env)->CallVoidMethodV(env, o, m, l);
    va_end(l);
}

static void nonvirtual_v_Void(JNIEnv *env, jobject o, jclass c, jmethodID m, ...) {
    va_list l;
    va_start(l, m);
    (*env)->CallNonvirtualVoidMethodV(env, o, c, m, l);
    va_end(l);
}

static void static_v_Void(JNIEnv *env, jclass c, jmethodID m, ...) {
    va_list l;
    va_start(l, m);
    (*env)->CallStaticVoidMethodV(env, c, m, l);
    va_end(l);
}

static jobject new_object_v(JNIEnv *env, jclass c, jmethodID m, ...) {
    va_list l;
    va_start(l, m);
    jobject r = (*env)->NewObjectV(env, c, m, l);
    va_end(l);
    return r;
}

#define VA ARG_I, ARG_J, ARG_F, ARG_D, expected_string

#define TEST_CALLS(Name, Type, descriptor, value)                                          \
    {                                                                                      \
        jmethodID virtual_id = E(GetMethodID, type, "call" #Name, ARGS_SIGNATURE descriptor); \
        jmethodID static_id = E(GetStaticMethodID, type, "static" #Name, ARGS_SIGNATURE descriptor); \
        CHECK(virtual_id != NULL && static_id != NULL);                                    \
        CHECK(matches_##Name((*env)->Call##Name##Method(env, object, virtual_id, VA)));    \
        CHECK(matches_##Name(virtual_v_##Name(env, object, virtual_id, VA)));              \
        CHECK(matches_##Name((*env)->Call##Name##MethodA(env, object, virtual_id, array))); \
        CHECK(matches_##Name((*env)->CallNonvirtual##Name##Method(env, object, type, virtual_id, VA))); \
        CHECK(matches_##Name(nonvirtual_v_##Name(env, object, type, virtual_id, VA)));     \
        CHECK(matches_##Name((*env)->CallNonvirtual##Name##MethodA(env, object, type, virtual_id, array))); \
        CHECK(matches_##Name((*env)->CallStatic##Name##Method(env, type, static_id, VA))); \
        CHECK(matches_##Name(static_v_##Name(env, type, static_id, VA)));                  \
        CHECK(matches_##Name((*env)->CallStatic##Name##MethodA(env, type, static_id, array))); \
    }

static int test_calls(JNIEnv *env) {
    jclass type = E(FindClass, SUBJECT);
    CHECK(type != NULL);
    CHECK(E(RegisterNatives, type, natives, sizeof(natives) / sizeof(natives[0])) == JNI_OK);
    jobject object = E(AllocObject, type);
    CHECK(object != NULL);
    expected_string = E(NewStringUTF, "argument");
    jvalue array[5];
    memset(array, 0, sizeof(array));
    array[0].i = ARG_I;
    array[1].j = ARG_J;
    array[2].f = ARG_F;
    array[3].d = ARG_D;
    array[4].l = expected_string;

    EACH_RETURNING(TEST_CALLS)

    jmethodID virtual_id = E(GetMethodID, type, "callVoid", ARGS_SIGNATURE "V");
    jmethodID static_id = E(GetStaticMethodID, type, "staticVoid", ARGS_SIGNATURE "V");
    int before = native_calls;
    (*env)->CallVoidMethod(env, object, virtual_id, VA);
    virtual_v_Void(env, object, virtual_id, VA);
    (*env)->CallVoidMethodA(env, object, virtual_id, array);
    (*env)->CallNonvirtualVoidMethod(env, object, type, virtual_id, VA);
    nonvirtual_v_Void(env, object, type, virtual_id, VA);
    (*env)->CallNonvirtualVoidMethodA(env, object, type, virtual_id, array);
    (*env)->CallStaticVoidMethod(env, type, static_id, VA);
    static_v_Void(env, type, static_id, VA);
    (*env)->CallStaticVoidMethodA(env, type, static_id, array);
    CHECK(native_calls == before + 9);
    CHECK(bad_arguments == 0);

    jmethodID many = E(GetMethodID, type, "many", "(IIIIIIIIFFDDDDDDDBS)J");
    jlong sum = (*env)->CallLongMethod(env, object, many, 1, 2, 3, 4, 5, 6, 7, 8, 0.5f, 0.5f, 1.0, 1.0, 1.0, 1.0,
                                       1.0, 1.0, 1.0, (jbyte)-2, (jshort)-3);
    CHECK(sum == 204 + 8 - 5);

    jmethodID constructor = E(GetMethodID, type, "<init>", "(I)V");
    jvalue value;
    value.i = 3;
    jobject first = (*env)->NewObject(env, type, constructor, 1);
    CHECK(first != NULL && constructed_with == 1);
    jobject second = new_object_v(env, type, constructor, 2);
    CHECK(second != NULL && constructed_with == 2);
    jobject third = (*env)->NewObjectA(env, type, constructor, &value);
    CHECK(third != NULL && constructed_with == 3);
    CHECK(E(IsInstanceOf, third, type));

    CHECK(E(UnregisterNatives, type) == JNI_OK);
    CHECK(E(RegisterNatives, type, natives, sizeof(natives) / sizeof(natives[0])) == JNI_OK);
    NO_EXCEPTION();
    return 0;
}

#define OBJECT_VALUE field_object
#define EACH_FIELD(M)                                                                      \
    M(Object, jobject, "Ljava/lang/String;", field_object, E(IsSameObject, got, field_object)) \
    M(Boolean, jboolean, "Z", JNI_TRUE, got == JNI_TRUE)                                   \
    M(Byte, jbyte, "B", -9, got == -9)                                                     \
    M(Char, jchar, "C", 0x41, got == 0x41)                                                 \
    M(Short, jshort, "S", -1234, got == -1234)                                             \
    M(Int, jint, "I", 99999, got == 99999)                                                 \
    M(Long, jlong, "J", -(1LL << 50), got == -(1LL << 50))                                 \
    M(Float, jfloat, "F", 0.25f, got == 0.25f)                                             \
    M(Double, jdouble, "D", 1e100, got == 1e100)

#define TEST_FIELD(Name, Type, descriptor, value, matches)                                 \
    {                                                                                      \
        jfieldID instance_id = E(GetFieldID, type, "field" #Name, descriptor);             \
        jfieldID static_id = E(GetStaticFieldID, type, "shared" #Name, descriptor);        \
        CHECK(instance_id != NULL && static_id != NULL);                                   \
        (*env)->Set##Name##Field(env, object, instance_id, value);                         \
        {                                                                                  \
            Type got = (*env)->Get##Name##Field(env, object, instance_id);                 \
            CHECK(matches);                                                                \
        }                                                                                  \
        (*env)->SetStatic##Name##Field(env, type, static_id, value);                       \
        {                                                                                  \
            Type got = (*env)->GetStatic##Name##Field(env, type, static_id);               \
            CHECK(matches);                                                                \
        }                                                                                  \
    }

static int test_fields(JNIEnv *env) {
    jclass type = E(FindClass, SUBJECT);
    jobject object = E(AllocObject, type);
    jobject field_object = E(NewStringUTF, "stored");
    EACH_FIELD(TEST_FIELD)
    NO_EXCEPTION();
    return 0;
}

#define EACH_ARRAY(M)                                                                      \
    M(Boolean, jboolean, 1)                                                                \
    M(Byte, jbyte, -3)                                                                     \
    M(Char, jchar, 0x1234)                                                                 \
    M(Short, jshort, -2345)                                                                \
    M(Int, jint, 345678)                                                                   \
    M(Long, jlong, 1LL << 45)                                                              \
    M(Float, jfloat, 6.5f)                                                                 \
    M(Double, jdouble, 7.75)

#define TEST_ARRAY(Name, Type, value)                                                      \
    {                                                                                      \
        jarray array = (*env)->New##Name##Array(env, 4);                                   \
        CHECK(array != NULL && E(GetArrayLength, array) == 4);                             \
        Type sample = value, copy = 0;                                                     \
        (*env)->Set##Name##ArrayRegion(env, array, 1, 1, &sample);                         \
        (*env)->Get##Name##ArrayRegion(env, array, 1, 1, &copy);                           \
        CHECK(copy == value);                                                              \
        jboolean is_copy = JNI_TRUE;                                                       \
        Type *elements = (*env)->Get##Name##ArrayElements(env, array, &is_copy);           \
        CHECK(elements != NULL && elements[1] == value && elements[0] == 0);               \
        elements[2] = value;                                                               \
        (*env)->Release##Name##ArrayElements(env, array, elements, JNI_COMMIT);            \
        (*env)->Release##Name##ArrayElements(env, array, elements, 0);                     \
        (*env)->Get##Name##ArrayRegion(env, array, 2, 1, &copy);                           \
        CHECK(copy == value);                                                              \
        (*env)->Get##Name##ArrayRegion(env, array, 3, 5, &copy);                           \
        CHECK(E0(ExceptionCheck));                                                         \
        E0(ExceptionClear);                                                                \
    }

static int test_arrays(JNIEnv *env) {
    EACH_ARRAY(TEST_ARRAY)

    jarray ints = E(NewIntArray, 2);
    jboolean is_copy;
    jint *critical = E(GetPrimitiveArrayCritical, ints, &is_copy);
    CHECK(critical != NULL);
    critical[1] = 5;
    (*env)->ReleasePrimitiveArrayCritical(env, ints, critical, 0);
    jint read = 0;
    E(GetIntArrayRegion, ints, 1, 1, &read);
    CHECK(read == 5);

    jclass string_class = E(FindClass, "java/lang/String");
    jstring initial = E(NewStringUTF, "initial");
    jobjectArray objects = E(NewObjectArray, 2, string_class, initial);
    CHECK(objects != NULL && E(GetArrayLength, objects) == 2);
    jobject element = E(GetObjectArrayElement, objects, 1);
    CHECK(E(IsSameObject, element, initial));
    jstring other = E(NewStringUTF, "other");
    E(SetObjectArrayElement, objects, 0, other);
    element = E(GetObjectArrayElement, objects, 0);
    CHECK(E(IsSameObject, element, other));
    E(GetObjectArrayElement, objects, 2);
    CHECK(E0(ExceptionCheck));
    E0(ExceptionClear);
    return 0;
}

static int test_strings(JNIEnv *env) {
    // A NUL as two bytes, and U+1D11E as a surrogate pair of three each.
    static const char utf[] = "a\xC0\x80\xED\xA0\xB4\xED\xB4\x9E";
    jstring text = E(NewStringUTF, utf);
    CHECK(text != NULL);
    CHECK(E(GetStringLength, text) == 4);
    CHECK(E(GetStringUTFLength, text) == 9);

    jboolean is_copy;
    const char *bytes = E(GetStringUTFChars, text, &is_copy);
    CHECK(bytes != NULL && strcmp(bytes, utf) == 0);
    E(ReleaseStringUTFChars, text, bytes);

    const jchar *units = E(GetStringChars, text, &is_copy);
    CHECK(units != NULL && units[0] == 'a' && units[1] == 0 && units[2] == 0xD834 && units[3] == 0xDD1E);
    E(ReleaseStringChars, text, units);

    units = E(GetStringCritical, text, &is_copy);
    CHECK(units != NULL && units[3] == 0xDD1E);
    E(ReleaseStringCritical, text, units);

    jchar region[2];
    E(GetStringRegion, text, 2, 2, region);
    CHECK(region[0] == 0xD834 && region[1] == 0xDD1E);
    char utf_region[8];
    E(GetStringUTFRegion, text, 0, 1, utf_region);
    CHECK(strcmp(utf_region, "a") == 0);
    E(GetStringRegion, text, 3, 2, region);
    CHECK(E0(ExceptionCheck));
    E0(ExceptionClear);

    const jchar raw[] = { 'h', 'i' };
    jstring made = E(NewString, raw, 2);
    bytes = E(GetStringUTFChars, made, NULL);
    CHECK(strcmp(bytes, "hi") == 0);
    E(ReleaseStringUTFChars, made, bytes);
    return 0;
}

static int test_references(JNIEnv *env) {
    jobject local = E(NewStringUTF, "reference");
    CHECK(E(GetObjectRefType, local) == JNILocalRefType);
    jobject another = E(NewLocalRef, local);
    CHECK(E(IsSameObject, local, another));
    E(DeleteLocalRef, another);
    CHECK(E(GetObjectRefType, another) == JNIInvalidRefType);

    jobject global = E(NewGlobalRef, local);
    CHECK(E(GetObjectRefType, global) == JNIGlobalRefType);
    jweak weak = E(NewWeakGlobalRef, local);
    CHECK(E(GetObjectRefType, weak) == JNIWeakGlobalRefType);
    CHECK(E(IsSameObject, weak, global));

    CHECK(E(EnsureLocalCapacity, 64) == JNI_OK);
    CHECK(E(PushLocalFrame, 8) == JNI_OK);
    jobject inner = E(NewStringUTF, "inner");
    jobject survivor = E(PopLocalFrame, inner);
    CHECK(E(GetObjectRefType, inner) == JNIInvalidRefType);
    CHECK(E(GetObjectRefType, survivor) == JNILocalRefType);

    CHECK(E(IsSameObject, NULL, NULL));
    CHECK(E(GetObjectRefType, NULL) == JNIInvalidRefType);
    E(DeleteWeakGlobalRef, weak);
    E(DeleteGlobalRef, global);
    CHECK(E(GetObjectRefType, global) == JNIInvalidRefType);
    return 0;
}

static int test_classes(JNIEnv *env) {
    CHECK(E0(GetVersion) == JNI_VERSION_1_6);

    jclass string_class = E(FindClass, "java/lang/String");
    jclass object_class = E(FindClass, "java/lang/Object");
    CHECK(string_class != NULL && object_class != NULL);
    CHECK(E(IsAssignableFrom, string_class, object_class));
    CHECK(!E(IsAssignableFrom, object_class, string_class));
    jclass parent = E(GetSuperclass, string_class);
    CHECK(E(IsSameObject, parent, object_class));
    CHECK(E(GetSuperclass, object_class) == NULL);

    jstring text = E(NewStringUTF, "text");
    jclass actual = E(GetObjectClass, text);
    CHECK(E(IsSameObject, actual, string_class));
    CHECK(E(IsInstanceOf, text, object_class));
    CHECK(E(IsInstanceOf, NULL, string_class));

    jmethodID length = E(GetMethodID, string_class, "length", "()I");
    CHECK(length != NULL);
    CHECK((*env)->CallIntMethod(env, text, length) == 4);

    // Virtual dispatch: Object's toString, on a String, is String's.
    jmethodID describe = E(GetMethodID, object_class, "toString", "()Ljava/lang/String;");
    jobject same = (*env)->CallObjectMethod(env, text, describe);
    CHECK(E(IsSameObject, same, text));

    jobject method_object = E(ToReflectedMethod, string_class, length, JNI_FALSE);
    CHECK(method_object != NULL);
    CHECK(E(FromReflectedMethod, method_object) == length);

    jclass subject = E(FindClass, SUBJECT);
    jfieldID field = E(GetFieldID, subject, "reflected", "I");
    jobject field_object = E(ToReflectedField, subject, field, JNI_FALSE);
    CHECK(field_object != NULL);
    CHECK(E(FromReflectedField, field_object) == field);

    jbyte code = 0;
    CHECK(E(DefineClass, "com/mead/Defined", NULL, &code, 1) == NULL);
    CHECK(E0(ExceptionCheck));
    E0(ExceptionClear);
    return 0;
}

static int test_exceptions(JNIEnv *env) {
    NO_EXCEPTION();
    jclass failure = E(FindClass, "java/lang/IllegalStateException");
    CHECK(E(ThrowNew, failure, "gone wrong") == JNI_OK);
    CHECK(E0(ExceptionCheck));
    jthrowable pending = E0(ExceptionOccurred);
    CHECK(pending != NULL);
    CHECK(E(IsInstanceOf, pending, failure));
    E0(ExceptionDescribe);
    E0(ExceptionClear);
    NO_EXCEPTION();
    CHECK(E0(ExceptionOccurred) == NULL);

    jclass throwable_class = E(FindClass, "java/lang/Throwable");
    jmethodID get_message = E(GetMethodID, throwable_class, "getMessage", "()Ljava/lang/String;");
    jstring message = (*env)->CallObjectMethod(env, pending, get_message);
    const char *bytes = E(GetStringUTFChars, message, NULL);
    CHECK(strcmp(bytes, "gone wrong") == 0);
    E(ReleaseStringUTFChars, message, bytes);

    CHECK(E(Throw, pending) == JNI_OK);
    CHECK(E0(ExceptionCheck));
    E0(ExceptionClear);

    jmethodID constructor = E(GetMethodID, failure, "<init>", "(Ljava/lang/String;)V");
    jstring text = E(NewStringUTF, "made by NewObject");
    jobject made = (*env)->NewObject(env, failure, constructor, text);
    CHECK(made != NULL && E(IsInstanceOf, made, failure));

    // Never called: it ends the process. That it's there is the test.
    CHECK((*env)->FatalError != NULL);
    return 0;
}

static int test_unimplemented(JNIEnv *env) {
    // Nothing implements this class. Lax mode answers with zeros and null,
    // and the trace turns what is asked here into stubs.
    jclass type = E(FindClass, "com/mead/fixture/Unimplemented$Inner");
    CHECK(type != NULL);
    jmethodID empty = E(GetMethodID, type, "<init>", "()V");
    jobject object = (*env)->NewObject(env, type, empty);
    CHECK(object != NULL);
    jmethodID with_value = E(GetMethodID, type, "<init>", "(I)V");
    CHECK(with_value != NULL);

    jmethodID work = E(GetMethodID, type, "doWork", "(ILjava/lang/String;)Ljava/lang/Object;");
    CHECK((*env)->CallObjectMethod(env, object, work, 1, NULL) == NULL);
    jmethodID number = E(GetStaticMethodID, type, "number", "(JD)F");
    CHECK((*env)->CallStaticFloatMethod(env, type, number, 1LL, 2.0) == 0.0f);
    jmethodID nothing = E(GetStaticMethodID, type, "nothing", "()V");
    (*env)->CallStaticVoidMethod(env, type, nothing);

    // Two overloads Swift cannot tell apart, and a name it reserves.
    E(GetMethodID, type, "take", "(Ljava/util/List;)V");
    E(GetMethodID, type, "take", "(Ljava/util/Map;)V");
    E(GetMethodID, type, "default", "()Z");

    jfieldID count = E(GetFieldID, type, "count", "I");
    CHECK(E(GetIntField, object, count) == 0);
    E(GetStaticFieldID, type, "NAME", "Ljava/lang/String;");
    NO_EXCEPTION();
    return 0;
}

static int test_monitors_and_buffers(JNIEnv *env) {
    jobject object = E(NewStringUTF, "lock");
    CHECK(E(MonitorEnter, object) == JNI_OK);
    CHECK(E(MonitorEnter, object) == JNI_OK);
    CHECK(E(MonitorExit, object) == JNI_OK);
    CHECK(E(MonitorExit, object) == JNI_OK);

    char memory[16];
    jobject buffer = E(NewDirectByteBuffer, memory, sizeof(memory));
    CHECK(buffer != NULL);
    CHECK(E(GetDirectBufferAddress, buffer) == memory);
    CHECK(E(GetDirectBufferCapacity, buffer) == sizeof(memory));
    return 0;
}

static JavaVM *the_vm;
static int thread_failure;

static void *attached_thread(void *argument) {
    (void)argument;
    JNIEnv *env = NULL;
#define THREAD_CHECK(condition) if (!(condition)) { thread_failure = __LINE__; return NULL; }
    THREAD_CHECK((*the_vm)->GetEnv(the_vm, (void **)&env, JNI_VERSION_1_6) == JNI_EDETACHED);
    THREAD_CHECK(env == NULL);
    THREAD_CHECK((*the_vm)->AttachCurrentThread(the_vm, &env, NULL) == JNI_OK);
    THREAD_CHECK(env != NULL);
    JNIEnv *again = NULL;
    THREAD_CHECK((*the_vm)->GetEnv(the_vm, (void **)&again, JNI_VERSION_1_6) == JNI_OK && again == env);

    jclass failure = E(FindClass, "java/lang/RuntimeException");
    THREAD_CHECK(E(ThrowNew, failure, "this thread's") == JNI_OK);
    THREAD_CHECK(E0(ExceptionCheck));
    E0(ExceptionClear);
    THREAD_CHECK((*the_vm)->DetachCurrentThread(the_vm) == JNI_OK);
    THREAD_CHECK((*the_vm)->GetEnv(the_vm, (void **)&env, JNI_VERSION_1_6) == JNI_EDETACHED);

    THREAD_CHECK((*the_vm)->AttachCurrentThreadAsDaemon(the_vm, &env, NULL) == JNI_OK);
    THREAD_CHECK((*the_vm)->DetachCurrentThread(the_vm) == JNI_OK);
    return NULL;
}

static int test_vm(JNIEnv *env) {
    JavaVM *vm = NULL;
    CHECK(E(GetJavaVM, &vm) == JNI_OK);
    CHECK(vm == the_vm);
    void *same = NULL;
    CHECK((*vm)->GetEnv(vm, &same, JNI_VERSION_1_6) == JNI_OK && same == env);
    CHECK((*vm)->GetEnv(vm, &same, 0x7fff) == JNI_EVERSION);
    CHECK((*vm)->DestroyJavaVM != NULL); // never called: the process needs it

    // An exception pending on this thread is not the other thread's.
    jclass failure = E(FindClass, "java/lang/RuntimeException");
    E(ThrowNew, failure, "the main thread's");
    pthread_t thread;
    CHECK(pthread_create(&thread, NULL, attached_thread, NULL) == 0);
    pthread_join(thread, NULL);
    CHECK(thread_failure == 0);
    CHECK(E0(ExceptionCheck));
    E0(ExceptionClear);
    return 0;
}

int mead_selftest(void) {
    jsize count = 0;
    CHECK(JNI_GetCreatedJavaVMs(&the_vm, 1, &count) == JNI_OK);
    CHECK(count == 1 && the_vm != NULL);
    JNIEnv *env = NULL;
    CHECK((*the_vm)->GetEnv(the_vm, (void **)&env, JNI_VERSION_1_6) == JNI_OK);
    CHECK(env != NULL);

    int (*const tests[])(JNIEnv *) = {
        test_calls, test_fields,     test_arrays,        test_strings,              test_references,
        test_classes, test_exceptions, test_unimplemented, test_monitors_and_buffers, test_vm,
    };
    for (size_t index = 0; index < sizeof(tests) / sizeof(tests[0]); index++) {
        int failed = tests[index](env);
        if (failed)
            return failed;
    }
    return 0;
}
