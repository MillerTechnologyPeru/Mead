#include "mead_jni.h"

#include <string.h>

// JNI's variadic entries, and the typed families: what Swift cannot write.

// A method's variadic arguments as an array, by what its signature says they
// are. Default promotions apply: what is smaller than an int came as an int,
// and a float came as a double.
static void unpack(jmethodID method, va_list list, jvalue *arguments) {
    const char *shorty = mead_jni_method_shorty(method);
    if (!shorty)
        return;
    size_t index = 0;
    for (const char *at = shorty + 1; *at; at++, index++) {
        memset(&arguments[index], 0, sizeof(jvalue));
        switch (*at) {
        case 'Z': arguments[index].z = (jboolean)va_arg(list, jint); break;
        case 'B': arguments[index].b = (jbyte)va_arg(list, jint); break;
        case 'C': arguments[index].c = (jchar)va_arg(list, jint); break;
        case 'S': arguments[index].s = (jshort)va_arg(list, jint); break;
        case 'I': arguments[index].i = va_arg(list, jint); break;
        case 'J': arguments[index].j = va_arg(list, jlong); break;
        case 'F': arguments[index].f = (jfloat)va_arg(list, jdouble); break;
        case 'D': arguments[index].d = va_arg(list, jdouble); break;
        default: arguments[index].l = va_arg(list, jobject); break;
        }
    }
}

// How many arguments a method takes; a JVM method has at most 255.
static size_t argument_count(jmethodID method) {
    const char *shorty = mead_jni_method_shorty(method);
    return shorty ? strlen(shorty) - 1 : 0;
}

#define CALL_BODY(mode, target, Type, member)                                              \
    {                                                                                      \
        jvalue result;                                                                     \
        memset(&result, 0, sizeof(result));                                                \
        mead_jni_invoke(env, mode, target, method, arguments, &result);                    \
        return result.member;                                                              \
    }

#define VOID_BODY(mode, target)                                                            \
    {                                                                                      \
        jvalue result;                                                                     \
        mead_jni_invoke(env, mode, target, method, arguments, &result);                    \
    }

#define DEFINE_FORMS(Prefix, Name, Type, mode, member, Parameters, target)                 \
    static Type Prefix##Name##MethodA(JNIEnv *env, Parameters, jmethodID method,           \
                                      const jvalue *arguments)                             \
        CALL_BODY(mode, target, Type, member)                                              \
    static Type Prefix##Name##MethodV(JNIEnv *env, Parameters, jmethodID method,           \
                                      va_list list) {                                      \
        jvalue arguments[argument_count(method) + 1];                                      \
        unpack(method, list, arguments);                                                   \
        CALL_BODY(mode, target, Type, member)                                              \
    }                                                                                      \
    static Type Prefix##Name##Method(JNIEnv *env, Parameters, jmethodID method, ...) {     \
        jvalue arguments[argument_count(method) + 1];                                      \
        va_list list;                                                                      \
        va_start(list, method);                                                            \
        unpack(method, list, arguments);                                                   \
        va_end(list);                                                                      \
        CALL_BODY(mode, target, Type, member)                                              \
    }

#define DEFINE_VOID_FORMS(Prefix, mode, Parameters, target)                                \
    static void Prefix##VoidMethodA(JNIEnv *env, Parameters, jmethodID method,             \
                                    const jvalue *arguments)                               \
        VOID_BODY(mode, target)                                                            \
    static void Prefix##VoidMethodV(JNIEnv *env, Parameters, jmethodID method,             \
                                    va_list list) {                                        \
        jvalue arguments[argument_count(method) + 1];                                      \
        unpack(method, list, arguments);                                                   \
        VOID_BODY(mode, target)                                                            \
    }                                                                                      \
    static void Prefix##VoidMethod(JNIEnv *env, Parameters, jmethodID method, ...) {       \
        jvalue arguments[argument_count(method) + 1];                                      \
        va_list list;                                                                      \
        va_start(list, method);                                                            \
        unpack(method, list, arguments);                                                   \
        va_end(list);                                                                      \
        VOID_BODY(mode, target)                                                            \
    }

#define DEFINE_FAMILY(Prefix, mode, Parameters, target)                                    \
    DEFINE_FORMS(Prefix, Object, jobject, mode, l, Parameters, target)                     \
    DEFINE_FORMS(Prefix, Boolean, jboolean, mode, z, Parameters, target)                   \
    DEFINE_FORMS(Prefix, Byte, jbyte, mode, b, Parameters, target)                         \
    DEFINE_FORMS(Prefix, Char, jchar, mode, c, Parameters, target)                         \
    DEFINE_FORMS(Prefix, Short, jshort, mode, s, Parameters, target)                       \
    DEFINE_FORMS(Prefix, Int, jint, mode, i, Parameters, target)                           \
    DEFINE_FORMS(Prefix, Long, jlong, mode, j, Parameters, target)                         \
    DEFINE_FORMS(Prefix, Float, jfloat, mode, f, Parameters, target)                       \
    DEFINE_FORMS(Prefix, Double, jdouble, mode, d, Parameters, target)                     \
    DEFINE_VOID_FORMS(Prefix, mode, Parameters, target)

DEFINE_FAMILY(Call, MEAD_JNI_VIRTUAL, jobject object, object)
DEFINE_FAMILY(CallStatic, MEAD_JNI_STATIC, jclass type, type)

// The nonvirtual family takes the class as well, which it has no use for:
// the method ID already says which implementation is meant.
#define DEFINE_NONVIRTUAL(Name, Type, member)                                              \
    static Type CallNonvirtual##Name##MethodA(JNIEnv *env, jobject object, jclass type,    \
                                              jmethodID method, const jvalue *arguments) { \
        (void)type;                                                                        \
        CALL_BODY(MEAD_JNI_NONVIRTUAL, object, Type, member)                               \
    }                                                                                      \
    static Type CallNonvirtual##Name##MethodV(JNIEnv *env, jobject object, jclass type,    \
                                              jmethodID method, va_list list) {            \
        (void)type;                                                                        \
        jvalue arguments[argument_count(method) + 1];                                      \
        unpack(method, list, arguments);                                                   \
        CALL_BODY(MEAD_JNI_NONVIRTUAL, object, Type, member)                               \
    }                                                                                      \
    static Type CallNonvirtual##Name##Method(JNIEnv *env, jobject object, jclass type,     \
                                             jmethodID method, ...) {                      \
        (void)type;                                                                        \
        jvalue arguments[argument_count(method) + 1];                                      \
        va_list list;                                                                      \
        va_start(list, method);                                                            \
        unpack(method, list, arguments);                                                   \
        va_end(list);                                                                      \
        CALL_BODY(MEAD_JNI_NONVIRTUAL, object, Type, member)                               \
    }

DEFINE_NONVIRTUAL(Object, jobject, l)
DEFINE_NONVIRTUAL(Boolean, jboolean, z)
DEFINE_NONVIRTUAL(Byte, jbyte, b)
DEFINE_NONVIRTUAL(Char, jchar, c)
DEFINE_NONVIRTUAL(Short, jshort, s)
DEFINE_NONVIRTUAL(Int, jint, i)
DEFINE_NONVIRTUAL(Long, jlong, j)
DEFINE_NONVIRTUAL(Float, jfloat, f)
DEFINE_NONVIRTUAL(Double, jdouble, d)

static void CallNonvirtualVoidMethodA(JNIEnv *env, jobject object, jclass type, jmethodID method,
                                      const jvalue *arguments) {
    (void)type;
    VOID_BODY(MEAD_JNI_NONVIRTUAL, object)
}

static void CallNonvirtualVoidMethodV(JNIEnv *env, jobject object, jclass type, jmethodID method,
                                      va_list list) {
    (void)type;
    jvalue arguments[argument_count(method) + 1];
    unpack(method, list, arguments);
    VOID_BODY(MEAD_JNI_NONVIRTUAL, object)
}

static void CallNonvirtualVoidMethod(JNIEnv *env, jobject object, jclass type, jmethodID method, ...) {
    (void)type;
    jvalue arguments[argument_count(method) + 1];
    va_list list;
    va_start(list, method);
    unpack(method, list, arguments);
    va_end(list);
    VOID_BODY(MEAD_JNI_NONVIRTUAL, object)
}

static jobject NewObjectA(JNIEnv *env, jclass type, jmethodID method, const jvalue *arguments) {
    return mead_jni_new_object(env, type, method, arguments);
}

static jobject NewObjectV(JNIEnv *env, jclass type, jmethodID method, va_list list) {
    jvalue arguments[argument_count(method) + 1];
    unpack(method, list, arguments);
    return mead_jni_new_object(env, type, method, arguments);
}

static jobject NewObject(JNIEnv *env, jclass type, jmethodID method, ...) {
    jvalue arguments[argument_count(method) + 1];
    va_list list;
    va_start(list, method);
    unpack(method, list, arguments);
    va_end(list);
    return mead_jni_new_object(env, type, method, arguments);
}

// Fields, by the member of jvalue each type lives in.
#define DEFINE_FIELD(Name, Type, member)                                                   \
    static Type Get##Name##Field(JNIEnv *env, jobject target, jfieldID field) {            \
        jvalue value;                                                                      \
        memset(&value, 0, sizeof(value));                                                  \
        mead_jni_get_field(env, target, field, &value);                                    \
        return value.member;                                                               \
    }                                                                                      \
    static void Set##Name##Field(JNIEnv *env, jobject target, jfieldID field, Type given) { \
        jvalue value;                                                                      \
        memset(&value, 0, sizeof(value));                                                  \
        value.member = given;                                                              \
        mead_jni_set_field(env, target, field, &value);                                    \
    }

DEFINE_FIELD(Object, jobject, l)
DEFINE_FIELD(Boolean, jboolean, z)
DEFINE_FIELD(Byte, jbyte, b)
DEFINE_FIELD(Char, jchar, c)
DEFINE_FIELD(Short, jshort, s)
DEFINE_FIELD(Int, jint, i)
DEFINE_FIELD(Long, jlong, j)
DEFINE_FIELD(Float, jfloat, f)
DEFINE_FIELD(Double, jdouble, d)

// Primitive arrays.
#define DEFINE_ARRAY(Name, Type, kind)                                                     \
    static jarray New##Name##Array(JNIEnv *env, jsize length) {                            \
        return mead_jni_new_array(env, kind, length);                                      \
    }                                                                                      \
    static Type *Get##Name##ArrayElements(JNIEnv *env, jarray array, jboolean *is_copy) {  \
        return mead_jni_array_elements(env, array, is_copy);                               \
    }                                                                                      \
    static void Release##Name##ArrayElements(JNIEnv *env, jarray array, Type *elements,    \
                                             jint mode) {                                  \
        mead_jni_array_release(env, array, elements, mode);                                \
    }                                                                                      \
    static void Get##Name##ArrayRegion(JNIEnv *env, jarray array, jsize start, jsize length, \
                                       Type *buffer) {                                     \
        mead_jni_array_region(env, array, start, length, buffer, JNI_FALSE);               \
    }                                                                                      \
    static void Set##Name##ArrayRegion(JNIEnv *env, jarray array, jsize start, jsize length, \
                                       const Type *buffer) {                               \
        mead_jni_array_region(env, array, start, length, (void *)buffer, JNI_TRUE);        \
    }

DEFINE_ARRAY(Boolean, jboolean, 'Z')
DEFINE_ARRAY(Byte, jbyte, 'B')
DEFINE_ARRAY(Char, jchar, 'C')
DEFINE_ARRAY(Short, jshort, 'S')
DEFINE_ARRAY(Int, jint, 'I')
DEFINE_ARRAY(Long, jlong, 'J')
DEFINE_ARRAY(Float, jfloat, 'F')
DEFINE_ARRAY(Double, jdouble, 'D')

static void *GetPrimitiveArrayCritical(JNIEnv *env, jarray array, jboolean *is_copy) {
    return mead_jni_array_elements(env, array, is_copy);
}

static void ReleasePrimitiveArrayCritical(JNIEnv *env, jarray array, void *elements, jint mode) {
    mead_jni_array_release(env, array, elements, mode);
}

#define CALLS(prefix)                                                                      \
    .prefix##ObjectMethod = prefix##ObjectMethod, .prefix##ObjectMethodV = prefix##ObjectMethodV, .prefix##ObjectMethodA = prefix##ObjectMethodA, \
    .prefix##BooleanMethod = prefix##BooleanMethod, .prefix##BooleanMethodV = prefix##BooleanMethodV, .prefix##BooleanMethodA = prefix##BooleanMethodA, \
    .prefix##ByteMethod = prefix##ByteMethod, .prefix##ByteMethodV = prefix##ByteMethodV, .prefix##ByteMethodA = prefix##ByteMethodA, \
    .prefix##CharMethod = prefix##CharMethod, .prefix##CharMethodV = prefix##CharMethodV, .prefix##CharMethodA = prefix##CharMethodA, \
    .prefix##ShortMethod = prefix##ShortMethod, .prefix##ShortMethodV = prefix##ShortMethodV, .prefix##ShortMethodA = prefix##ShortMethodA, \
    .prefix##IntMethod = prefix##IntMethod, .prefix##IntMethodV = prefix##IntMethodV, .prefix##IntMethodA = prefix##IntMethodA, \
    .prefix##LongMethod = prefix##LongMethod, .prefix##LongMethodV = prefix##LongMethodV, .prefix##LongMethodA = prefix##LongMethodA, \
    .prefix##FloatMethod = prefix##FloatMethod, .prefix##FloatMethodV = prefix##FloatMethodV, .prefix##FloatMethodA = prefix##FloatMethodA, \
    .prefix##DoubleMethod = prefix##DoubleMethod, .prefix##DoubleMethodV = prefix##DoubleMethodV, .prefix##DoubleMethodA = prefix##DoubleMethodA, \
    .prefix##VoidMethod = prefix##VoidMethod, .prefix##VoidMethodV = prefix##VoidMethodV, .prefix##VoidMethodA = prefix##VoidMethodA,

#define FIELDS(table, name)                                                                \
    .table##ObjectField = name##ObjectField, .table##BooleanField = name##BooleanField, .table##ByteField = name##ByteField, \
    .table##CharField = name##CharField, .table##ShortField = name##ShortField, .table##IntField = name##IntField, \
    .table##LongField = name##LongField, .table##FloatField = name##FloatField, .table##DoubleField = name##DoubleField,

#define ARRAYS(Name)                                                                       \
    .New##Name##Array = New##Name##Array, .Get##Name##ArrayElements = Get##Name##ArrayElements, \
    .Release##Name##ArrayElements = Release##Name##ArrayElements, .Get##Name##ArrayRegion = Get##Name##ArrayRegion, \
    .Set##Name##ArrayRegion = Set##Name##ArrayRegion,

#define DIRECT(name) .name = mead_jni_##name

static const struct JNINativeInterface functions = {
    DIRECT(GetVersion), DIRECT(DefineClass), DIRECT(FindClass), DIRECT(FromReflectedMethod),
    DIRECT(FromReflectedField), DIRECT(ToReflectedMethod), DIRECT(GetSuperclass),
    DIRECT(IsAssignableFrom), DIRECT(ToReflectedField), DIRECT(Throw), DIRECT(ThrowNew),
    DIRECT(ExceptionOccurred), DIRECT(ExceptionDescribe), DIRECT(ExceptionClear),
    DIRECT(FatalError), DIRECT(PushLocalFrame), DIRECT(PopLocalFrame), DIRECT(NewGlobalRef),
    DIRECT(DeleteGlobalRef), DIRECT(DeleteLocalRef), DIRECT(IsSameObject), DIRECT(NewLocalRef),
    DIRECT(EnsureLocalCapacity), DIRECT(AllocObject),
    .NewObject = NewObject, .NewObjectV = NewObjectV, .NewObjectA = NewObjectA,
    DIRECT(GetObjectClass), DIRECT(IsInstanceOf), DIRECT(GetMethodID),
    CALLS(Call)
    CALLS(CallNonvirtual)
    DIRECT(GetFieldID),
    FIELDS(Get, Get)
    FIELDS(Set, Set)
    DIRECT(GetStaticMethodID),
    CALLS(CallStatic)
    DIRECT(GetStaticFieldID),
    FIELDS(GetStatic, Get)
    FIELDS(SetStatic, Set)
    DIRECT(NewString), DIRECT(GetStringLength), DIRECT(GetStringChars), DIRECT(ReleaseStringChars),
    DIRECT(NewStringUTF), DIRECT(GetStringUTFLength), DIRECT(GetStringUTFChars),
    DIRECT(ReleaseStringUTFChars), DIRECT(GetArrayLength), DIRECT(NewObjectArray),
    DIRECT(GetObjectArrayElement), DIRECT(SetObjectArrayElement),
    ARRAYS(Boolean) ARRAYS(Byte) ARRAYS(Char) ARRAYS(Short) ARRAYS(Int) ARRAYS(Long) ARRAYS(Float) ARRAYS(Double)
    DIRECT(RegisterNatives), DIRECT(UnregisterNatives), DIRECT(MonitorEnter), DIRECT(MonitorExit),
    DIRECT(GetJavaVM), DIRECT(GetStringRegion), DIRECT(GetStringUTFRegion),
    .GetPrimitiveArrayCritical = GetPrimitiveArrayCritical,
    .ReleasePrimitiveArrayCritical = ReleasePrimitiveArrayCritical,
    DIRECT(GetStringCritical), DIRECT(ReleaseStringCritical), DIRECT(NewWeakGlobalRef),
    DIRECT(DeleteWeakGlobalRef), DIRECT(ExceptionCheck), DIRECT(NewDirectByteBuffer),
    DIRECT(GetDirectBufferAddress), DIRECT(GetDirectBufferCapacity), DIRECT(GetObjectRefType),
};

static const struct JNIInvokeInterface invoke_functions = {
    DIRECT(DestroyJavaVM), DIRECT(AttachCurrentThread), DIRECT(DetachCurrentThread),
    DIRECT(GetEnv), DIRECT(AttachCurrentThreadAsDaemon),
};

const struct JNINativeInterface *mead_jni_function_table(void) {
    return &functions;
}

const struct JNIInvokeInterface *mead_jni_invoke_table(void) {
    return &invoke_functions;
}

// Calls `function` with up to eight integer and eight floating-point
// register arguments, and the rest on the stack; leaves x0 and d0 in
// result[0] and result[1].
extern void mead_jni_trampoline(void *function, const uint64_t *integers, const uint64_t *floats,
                                const uint64_t *stack, uint64_t stack_bytes, uint64_t *result);
__asm__(".text\n"
        ".type mead_jni_trampoline, %function\n"
        "mead_jni_trampoline:\n"
        "    stp x29, x30, [sp, #-32]!\n"
        "    str x19, [sp, #16]\n"
        "    mov x29, sp\n"
        "    mov x19, x5\n"
        "    mov x16, x0\n"
        "    mov x17, x1\n"
        "    add x9, x4, #15\n"
        "    and x9, x9, #-16\n"
        "    sub sp, sp, x9\n"
        "    mov x10, #0\n"
        "1:  cmp x10, x4\n"
        "    b.hs 2f\n"
        "    ldr x11, [x3, x10]\n"
        "    str x11, [sp, x10]\n"
        "    add x10, x10, #8\n"
        "    b 1b\n"
        "2:  ldp d0, d1, [x2]\n"
        "    ldp d2, d3, [x2, #16]\n"
        "    ldp d4, d5, [x2, #32]\n"
        "    ldp d6, d7, [x2, #48]\n"
        "    ldp x0, x1, [x17]\n"
        "    ldp x2, x3, [x17, #16]\n"
        "    ldp x4, x5, [x17, #32]\n"
        "    ldp x6, x7, [x17, #48]\n"
        "    blr x16\n"
        "    str x0, [x19]\n"
        "    str d0, [x19, #8]\n"
        "    mov sp, x29\n"
        "    ldr x19, [sp, #16]\n"
        "    ldp x29, x30, [sp], #32\n"
        "    ret\n"
        ".size mead_jni_trampoline, . - mead_jni_trampoline\n");

void mead_jni_call_native(void *function, JNIEnv *env, jobject receiver, const char *shorty,
                          const jvalue *arguments, jvalue *result) {
    uint64_t integers[8] = { (uint64_t)(uintptr_t)env, (uint64_t)(uintptr_t)receiver };
    uint64_t floats[8] = { 0 };
    size_t count = strlen(shorty + 1);
    uint64_t stack[count + 1];
    size_t next_integer = 2, next_float = 0, on_stack = 0;
    for (size_t index = 0; index < count; index++) {
        const jvalue *argument = &arguments[index];
        char kind = shorty[index + 1];
        if (kind == 'F' || kind == 'D') {
            uint64_t bits = 0;
            memcpy(&bits, argument, kind == 'F' ? sizeof(jfloat) : sizeof(jdouble));
            if (next_float < 8)
                floats[next_float++] = bits;
            else
                stack[on_stack++] = bits;
            continue;
        }
        uint64_t bits;
        switch (kind) {
        case 'Z': bits = argument->z; break;
        case 'B': bits = (uint64_t)(int64_t)argument->b; break;
        case 'C': bits = argument->c; break;
        case 'S': bits = (uint64_t)(int64_t)argument->s; break;
        case 'I': bits = (uint64_t)(int64_t)argument->i; break;
        case 'J': bits = (uint64_t)argument->j; break;
        default: bits = (uint64_t)(uintptr_t)argument->l; break;
        }
        if (next_integer < 8)
            integers[next_integer++] = bits;
        else
            stack[on_stack++] = bits;
    }

    uint64_t returned[2] = { 0 };
    mead_jni_trampoline(function, integers, floats, stack, on_stack * sizeof(uint64_t), returned);
    memset(result, 0, sizeof(*result));
    switch (shorty[0]) {
    case 'V': break;
    case 'Z': result->z = (jboolean)returned[0]; break;
    case 'B': result->b = (jbyte)returned[0]; break;
    case 'C': result->c = (jchar)returned[0]; break;
    case 'S': result->s = (jshort)returned[0]; break;
    case 'I': result->i = (jint)returned[0]; break;
    case 'J': result->j = (jlong)returned[0]; break;
    case 'F': memcpy(&result->f, &returned[1], sizeof(jfloat)); break;
    case 'D': memcpy(&result->d, &returned[1], sizeof(jdouble)); break;
    default: result->l = (jobject)(uintptr_t)returned[0]; break;
    }
}
