import Glibc
import MeadJNI
import Testing
@testable import MeadJNI

// The runtime as native code meets it, through the entries behind the JNI
// tables; the C tables themselves are tested by the conformance fixture.

@JavaClass("com/mead/tests/Sample")
class Sample: JavaObject {
    @JavaField("count") var count: Int32 = 5
    @JavaField("label") var label: String? = "start"
    @JavaField("total") static var total: Int64 = 0

    var constructedWith: Int32 = 0

    @JavaMethod override init() {
        super.init()
    }

    @JavaMethod init(value: Int32) {
        constructedWith = value
        super.init()
    }

    @JavaMethod func add(_ first: Int32, second: Int64) -> Int64 {
        Int64(first) + second
    }

    @JavaMethod func greet(_ name: String?) -> String? {
        name.map { "hello \($0)" }
    }

    @JavaMethod static func twice(_ value: Double) -> Double {
        value * 2
    }

    @JavaMethod func fails() throws -> Bool {
        throw JavaException("java/lang/IllegalStateException", "no")
    }

    @JavaMethod func nothing() {}

    @JavaMethod func kind() -> String? {
        "sample"
    }
}

@JavaClass("com/mead/tests/SampleChild")
final class SampleChild: Sample {
    @JavaMethod override func kind() -> String? {
        "child"
    }
}

private struct Fixture {
    let thread = JavaRuntime.shared.attachCurrentThread()
    var env: UnsafeMutableRawPointer { UnsafeMutableRawPointer(thread.block) }
    let type = JavaRuntime.shared.defineClass(for: Sample.self)

    func method(_ name: String, _ signature: String, isStatic: Bool = false) -> OpaquePointer {
        type.method(named: name, signature: signature, isStatic: isStatic)!.id
    }

    func call(_ method: OpaquePointer, on target: OpaquePointer?, mode: Int = MEAD_JNI_VIRTUAL, _ arguments: [jvalue] = []) -> jvalue {
        var result = jvalue()
        arguments.withUnsafeBufferPointer {
            jni_invoke(env, Int32(mode), target, method, $0.baseAddress, &result)
        }
        return result
    }
}

private func int(_ value: Int32) -> jvalue {
    var result = jvalue()
    result.i = value
    return result
}

private func long(_ value: Int64) -> jvalue {
    var result = jvalue()
    result.j = value
    return result
}

@Test func theMacroDerivesSignaturesFromSwiftTypes() {
    let type = Fixture().type
    #expect(type.name == "com/mead/tests/Sample")
    for (name, signature) in [
        ("add", "(IJ)J"), ("greet", "(Ljava/lang/String;)Ljava/lang/String;"), ("twice", "(D)D"),
        ("fails", "()Z"), ("nothing", "()V"), ("<init>", "()V"), ("<init>", "(I)V"),
    ] {
        #expect(type.methods[MemberKey(name: name, signature: signature)] != nil, "\(name)\(signature)")
    }
    #expect(type.fields[MemberKey(name: "count", signature: "I")] != nil)
    #expect(type.fields[MemberKey(name: "label", signature: "Ljava/lang/String;")] != nil)
    #expect(type.superclass?.name == "java/lang/Object")
    #expect(JavaRuntime.shared.defineClass(for: SampleChild.self).superclass === type)
}

@Test func argumentsAndResultsCrossTheBoundary() {
    let fixture = Fixture()
    let thread = fixture.thread
    let object = thread.newLocal(Sample())
    let sum = fixture.call(fixture.method("add", "(IJ)J"), on: object, [int(2), long(40)])
    #expect(sum.j == 42)

    var name = jvalue()
    name.l = thread.newLocal(JavaString("world"))
    let greeting = fixture.call(fixture.method("greet", "(Ljava/lang/String;)Ljava/lang/String;"), on: object, [name])
    #expect((thread.resolve(greeting.l) as? JavaString)?.swiftValue == "hello world")

    var null = jvalue()
    null.l = nil
    let noGreeting = fixture.call(fixture.method("greet", "(Ljava/lang/String;)Ljava/lang/String;"), on: object, [null])
    #expect(noGreeting.l == nil)

    var value = jvalue()
    value.d = 2.5
    let doubled = fixture.call(fixture.method("twice", "(D)D", isStatic: true), on: nil, mode: MEAD_JNI_STATIC, [value])
    #expect(doubled.d == 5)
}

@Test func constructorsRunAndTakeTheClassAskedFor() {
    let fixture = Fixture()
    let thread = fixture.thread
    let constructor = fixture.method("<init>", "(I)V")
    var argument = int(9)
    let made = jni_new_object(fixture.env, thread.newLocal(fixture.type), constructor, &argument)
    #expect((thread.resolve(made) as? Sample)?.constructedWith == 9)

    // A class without its own constructors gets its parent's.
    let child = JavaRuntime.shared.defineClass(for: SampleChild.self)
    let childMade = jni_new_object(fixture.env, thread.newLocal(child), fixture.method("<init>", "()V"), nil)
    #expect(thread.resolve(childMade)?.javaClass === child)
}

@Test func virtualCallsTakeTheObjectsOwnMethod() {
    let fixture = Fixture()
    let thread = fixture.thread
    let child = thread.newLocal(SampleChild())
    let kind = fixture.method("kind", "()Ljava/lang/String;")
    let virtual = fixture.call(kind, on: child, mode: MEAD_JNI_VIRTUAL)
    #expect(JavaMethod.from(kind).owner.name == "com/mead/tests/Sample", "the ID was the parent's")
    #expect((thread.resolve(virtual.l) as? JavaString)?.swiftValue == "child")
}

@Test func aThrownErrorBecomesThePendingException() {
    let fixture = Fixture()
    let thread = fixture.thread
    defer { thread.pending = nil }
    _ = fixture.call(fixture.method("fails", "()Z"), on: thread.newLocal(Sample()))
    #expect(jni_ExceptionCheck(fixture.env) == 1)
    #expect(thread.pending?.javaClass.name == "java/lang/IllegalStateException")
    #expect(thread.pending?.message == "no")
    jni_ExceptionClear(fixture.env)
    #expect(jni_ExceptionCheck(fixture.env) == 0)
}

@Test func aCallOnNullRaisesNullPointerException() {
    let fixture = Fixture()
    defer { fixture.thread.pending = nil }
    _ = fixture.call(fixture.method("nothing", "()V"), on: nil)
    #expect(fixture.thread.pending?.javaClass.name == "java/lang/NullPointerException")
}

@Test func fieldsReadAndWriteTheSwiftProperties() {
    let fixture = Fixture()
    let thread = fixture.thread
    let instance = Sample()
    let object = thread.newLocal(instance)
    let count = fixture.type.field(named: "count", signature: "I", isStatic: false)!.id
    var result = jvalue()
    jni_get_field(fixture.env, object, count, &result)
    #expect(result.i == 5)
    var value = int(77)
    jni_set_field(fixture.env, object, count, &value)
    #expect(instance.count == 77)

    let label = fixture.type.field(named: "label", signature: "Ljava/lang/String;", isStatic: false)!.id
    jni_get_field(fixture.env, object, label, &result)
    #expect((thread.resolve(result.l) as? JavaString)?.swiftValue == "start")

    let total = fixture.type.field(named: "total", signature: "J", isStatic: true)!.id
    var large = long(1 << 40)
    jni_set_field(fixture.env, nil, total, &large)
    #expect(Sample.total == 1 << 40)
}

// MARK: References

@Test func aDeletedLocalReferenceIsStale() {
    let fixture = Fixture()
    let thread = fixture.thread
    let handle = thread.newLocal(JavaString("gone"))
    #expect(jni_GetObjectRefType(fixture.env, handle) == JNILocalRefType)
    jni_DeleteLocalRef(fixture.env, handle)
    #expect(jni_GetObjectRefType(fixture.env, handle) == JNIInvalidRefType)
    #expect(thread.resolve(handle) == nil)
    // The next reference may reuse the slot; the old handle stays stale.
    let reused = thread.newLocal(JavaString("new"))
    #expect(thread.resolve(reused) != nil)
    #expect(thread.resolve(handle) == nil)
}

@Test func poppingAFrameEndsItsReferencesAndKeepsTheResult() {
    let fixture = Fixture()
    let thread = fixture.thread
    let outside = thread.newLocal(JavaString("outside"))
    jni_PushLocalFrame(fixture.env, 4)
    let inner = thread.newLocal(JavaString("inner"))
    let other = thread.newLocal(JavaString("other"))
    let kept = jni_PopLocalFrame(fixture.env, inner)
    #expect(thread.resolve(inner) == nil || inner == kept)
    #expect(thread.resolve(other) == nil)
    #expect((thread.resolve(kept) as? JavaString)?.swiftValue == "inner")
    #expect((thread.resolve(outside) as? JavaString)?.swiftValue == "outside")
}

@Test func nestedFramesDoNotDisturbEachOther() {
    let fixture = Fixture()
    let thread = fixture.thread
    jni_PushLocalFrame(fixture.env, 4)
    let first = thread.newLocal(JavaString("first"))
    jni_PushLocalFrame(fixture.env, 4)
    let second = thread.newLocal(JavaString("second"))
    #expect(jni_PopLocalFrame(fixture.env, nil) == nil)
    #expect(thread.resolve(second) == nil)
    #expect((thread.resolve(first) as? JavaString)?.swiftValue == "first")
    _ = jni_PopLocalFrame(fixture.env, nil)
    #expect(thread.resolve(first) == nil)
}

@Test func globalReferencesOutliveLocalsAndGoStaleWhenDeleted() {
    let fixture = Fixture()
    let thread = fixture.thread
    let local = thread.newLocal(JavaString("kept"))
    let global = jni_NewGlobalRef(fixture.env, local)
    jni_DeleteLocalRef(fixture.env, local)
    #expect((thread.resolve(global) as? JavaString)?.swiftValue == "kept")
    #expect(jni_GetObjectRefType(fixture.env, global) == JNIGlobalRefType)
    jni_DeleteGlobalRef(fixture.env, global)
    #expect(jni_GetObjectRefType(fixture.env, global) == JNIInvalidRefType)
    #expect(thread.resolve(global) == nil)
}

@Test func aWeakReferenceDoesNotKeepItsObject() {
    let fixture = Fixture()
    let thread = fixture.thread
    var weak: OpaquePointer?
    do {
        let local = thread.newLocal(JavaString("temporary"))
        weak = jni_NewWeakGlobalRef(fixture.env, local)
        #expect(thread.resolve(weak) != nil)
        jni_DeleteLocalRef(fixture.env, local)
    }
    #expect(thread.resolve(weak) == nil)
    #expect(jni_IsSameObject(fixture.env, weak, nil) == 1)
    jni_DeleteWeakGlobalRef(fixture.env, weak)
}

@Test func handlesAreNeverPointers() {
    let fixture = Fixture()
    let handle = fixture.thread.newLocal(JavaString("opaque"))
    #expect(UInt(bitPattern: handle) & 3 == ReferenceKind.local.rawValue)
    #expect(Handle(handle)?.kind == .local)
}

// MARK: Strings and arrays

@Test func modifiedUTF8EncodesNULAsTwoBytes() {
    #expect(ModifiedUTF8.encode([0x61, 0x00]) == [0x61, 0xc0, 0x80])
}

@Test func modifiedUTF8EncodesSupplementaryCharactersAsSurrogates() {
    let units = Array("\u{1D11E}".utf16)
    #expect(units == [0xd834, 0xdd1e])
    #expect(ModifiedUTF8.encode(units) == [0xed, 0xa0, 0xb4, 0xed, 0xb4, 0x9e])
}

@Test func modifiedUTF8DecodesItsOwnEncoding() {
    let units: [UInt16] = [0x24, 0xa2, 0x20ac, 0x00, 0xd834, 0xdd1e]
    var bytes = ModifiedUTF8.encode(units).map { CChar(bitPattern: $0) }
    bytes.append(0)
    #expect(ModifiedUTF8.decode(bytes) == units)
}

@Test func modifiedUTF8ToleratesFourByteSequences() {
    let bytes: [CChar] = [0xf0, 0x9d, 0x84, 0x9e, 0x00].map { CChar(bitPattern: UInt8($0)) }
    #expect(ModifiedUTF8.decode(bytes) == [0xd834, 0xdd1e])
}

@Test func shortiesPutTheReturnFirstAndFoldReferences() {
    #expect(shortyOf("(ILjava/lang/String;[J[[Lfoo/Bar;Z)V") == "VILLLZ")
    #expect(shortyOf("()[I") == "L")
    #expect(shortyOf("(DF)Ljava/lang/Object;") == "LDF")
}

@Test func primitiveArraysArePinnedAndCheckTheirBounds() {
    let fixture = Fixture()
    let thread = fixture.thread
    defer { thread.pending = nil }
    let array = jni_new_array(fixture.env, CChar(UInt8(ascii: "I")), 4)
    var isCopy: jboolean = 1
    let elements = jni_array_elements(fixture.env, array, &isCopy)!.assumingMemoryBound(to: jint.self)
    #expect(isCopy == 0)
    elements[3] = 12
    jni_array_release(fixture.env, array, elements, 0)
    var copy: jint = 0
    jni_array_region(fixture.env, array, 3, 1, &copy, 0)
    #expect(copy == 12)
    jni_array_region(fixture.env, array, 4, 1, &copy, 0)
    #expect(thread.pending?.javaClass.name == "java/lang/ArrayIndexOutOfBoundsException")
}

// MARK: Binding natives by name

@Test func nativeNamesAreMangledAsJNISays() {
    #expect(jniShortName(owner: "com/foo/Bar", method: "baz") == "Java_com_foo_Bar_baz")
    #expect(jniShortName(owner: "com/foo_bar/Baz$Inner", method: "qu_x") == "Java_com_foo_1bar_Baz_00024Inner_qu_1x")
    #expect(jniLongName(owner: "a/B", method: "c", signature: "(I[Ljava/lang/String;)V") == "Java_a_B_c__I_3Ljava_lang_String_2")
    #expect(jniLongName(owner: "a/B", method: "c", signature: "()V") == "Java_a_B_c__")
}

// MARK: Tracing

@Test func theTracedStubsAreRealClasses() {
    // That GeneratedStubs.swift compiled is half the test.
    let inner = JavaRuntime.shared.defineClass(for: Com_mead_fixture_Unimplemented_Inner.self)
    #expect(inner.name == "com/mead/fixture/Unimplemented$Inner")
    #expect(inner.methods[MemberKey(name: "take", signature: "(Ljava/util/List;)V")] != nil)
    #expect(inner.methods[MemberKey(name: "take", signature: "(Ljava/util/Map;)V")] != nil)
    #expect(inner.methods[MemberKey(name: "default", signature: "()Z")] != nil)
    #expect(inner.fields[MemberKey(name: "NAME", signature: "Ljava/lang/String;")] != nil)
}

@Test func aStubAnswersWithZero() {
    let stub = Com_mead_fixture_Unimplemented_Inner()
    #expect(stub.default() == false)
    #expect(Com_mead_fixture_Unimplemented_Inner.number(1, 2) == 0)
    #expect(stub.doWork(1, nil) == nil)
}

@Test func unknownThingsAreStoodInForAndRecorded() {
    let fixture = Fixture()
    let thread = fixture.thread
    let handle = jni_FindClass(fixture.env, "com/mead/tests/NeverDefined")
    let type = thread.resolve(handle) as? JavaClass
    #expect(type?.isSynthesized == true)
    let method = type?.method(named: "ask", signature: "(I)J", isStatic: false)
    #expect(method?.isSynthesized == true)
    #expect(JavaRuntime.shared.generatedStubs().contains("@JavaClass(\"com/mead/tests/NeverDefined\")"))
    #expect(JavaRuntime.shared.generatedStubs().contains("@JavaMethod(\"ask\", signature: \"(I)J\")"))
}
