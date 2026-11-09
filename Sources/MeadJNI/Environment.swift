import Glibc

// The Swift side of the JNI function tables in CMeadJNI, entry by entry.
// Every one starts by finding the thread from the JNIEnv it was given.

private typealias Env = UnsafeMutableRawPointer
private typealias Reference = OpaquePointer

private func thread(_ env: Env) -> JavaThread {
    JavaThread.from(env)
}

private func classOf(_ pointer: Reference?, in thread: JavaThread) -> JavaClass? {
    thread.resolve(pointer) as? JavaClass
}

private func zero() -> jvalue {
    jvalue()
}

// MARK: Versions and classes

@_cdecl("mead_jni_GetVersion")
public func jni_GetVersion(_ env: UnsafeMutableRawPointer) -> jint {
    jint(JNI_VERSION_1_6)
}

@_cdecl("mead_jni_DefineClass")
public func jni_DefineClass(_ env: UnsafeMutableRawPointer, _ name: UnsafePointer<CChar>?, _ loader: OpaquePointer?, _ bytes: UnsafePointer<jbyte>?, _ size: jsize) -> OpaquePointer? {
    let current = thread(env)
    JavaRuntime.shared.problem("DefineClass: mead runs no bytecode")
    current.raise("java/lang/NoClassDefFoundError", name.map { String(cString: $0) })
    return nil
}

@_cdecl("mead_jni_FindClass")
public func jni_FindClass(_ env: UnsafeMutableRawPointer, _ name: UnsafePointer<CChar>) -> OpaquePointer? {
    let current = thread(env)
    return current.newLocal(JavaRuntime.shared.findClass(named: String(cString: name)))
}

@_cdecl("mead_jni_GetSuperclass")
public func jni_GetSuperclass(_ env: UnsafeMutableRawPointer, _ type: OpaquePointer?) -> OpaquePointer? {
    let current = thread(env)
    guard let definition = classOf(type, in: current), !definition.isInterface else { return nil }
    return current.newLocal(definition.superclass)
}

@_cdecl("mead_jni_IsAssignableFrom")
public func jni_IsAssignableFrom(_ env: UnsafeMutableRawPointer, _ from: OpaquePointer?, _ to: OpaquePointer?) -> jboolean {
    let current = thread(env)
    guard let source = classOf(from, in: current), let target = classOf(to, in: current) else { return 0 }
    return source.isSubclass(of: target) ? 1 : 0
}

@_cdecl("mead_jni_GetObjectClass")
public func jni_GetObjectClass(_ env: UnsafeMutableRawPointer, _ object: OpaquePointer?) -> OpaquePointer? {
    let current = thread(env)
    return current.newLocal(current.resolve(object)?.javaClass)
}

@_cdecl("mead_jni_IsInstanceOf")
public func jni_IsInstanceOf(_ env: UnsafeMutableRawPointer, _ object: OpaquePointer?, _ type: OpaquePointer?) -> jboolean {
    let current = thread(env)
    guard let instance = current.resolve(object) else { return 1 }
    guard let target = classOf(type, in: current) else { return 0 }
    return instance.javaClass.isSubclass(of: target) ? 1 : 0
}

// MARK: Reflection

@_cdecl("mead_jni_FromReflectedMethod")
public func jni_FromReflectedMethod(_ env: UnsafeMutableRawPointer, _ member: OpaquePointer?) -> OpaquePointer? {
    (thread(env).resolve(member) as? JavaReflectedMember)?.method?.id
}

@_cdecl("mead_jni_FromReflectedField")
public func jni_FromReflectedField(_ env: UnsafeMutableRawPointer, _ member: OpaquePointer?) -> OpaquePointer? {
    (thread(env).resolve(member) as? JavaReflectedMember)?.field?.id
}

@_cdecl("mead_jni_ToReflectedMethod")
public func jni_ToReflectedMethod(_ env: UnsafeMutableRawPointer, _ type: OpaquePointer?, _ method: OpaquePointer?, _ isStatic: jboolean) -> OpaquePointer? {
    guard let method else { return nil }
    return thread(env).newLocal(JavaReflectedMember(method: JavaMethod.from(method), field: nil))
}

@_cdecl("mead_jni_ToReflectedField")
public func jni_ToReflectedField(_ env: UnsafeMutableRawPointer, _ type: OpaquePointer?, _ field: OpaquePointer?, _ isStatic: jboolean) -> OpaquePointer? {
    guard let field else { return nil }
    return thread(env).newLocal(JavaReflectedMember(method: nil, field: JavaField.from(field)))
}

// MARK: Exceptions

@_cdecl("mead_jni_Throw")
public func jni_Throw(_ env: UnsafeMutableRawPointer, _ throwable: OpaquePointer?) -> jint {
    let current = thread(env)
    guard let exception = current.resolve(throwable) as? JavaThrowable else { return jint(JNI_ERR) }
    current.pending = exception
    return jint(JNI_OK)
}

@_cdecl("mead_jni_ThrowNew")
public func jni_ThrowNew(_ env: UnsafeMutableRawPointer, _ type: OpaquePointer?, _ message: UnsafePointer<CChar>?) -> jint {
    let current = thread(env)
    guard let definition = classOf(type, in: current) else { return jint(JNI_ERR) }
    current.pending = JavaThrowable(javaClass: definition, message: message.map { String(cString: $0) })
    return jint(JNI_OK)
}

@_cdecl("mead_jni_ExceptionOccurred")
public func jni_ExceptionOccurred(_ env: UnsafeMutableRawPointer) -> OpaquePointer? {
    let current = thread(env)
    return current.newLocal(current.pending)
}

@_cdecl("mead_jni_ExceptionDescribe")
public func jni_ExceptionDescribe(_ env: UnsafeMutableRawPointer) {
    if let pending = thread(env).pending {
        writeStandardError("mead(jni): pending exception: \(pending.describe() ?? "")\n")
    }
}

@_cdecl("mead_jni_ExceptionClear")
public func jni_ExceptionClear(_ env: UnsafeMutableRawPointer) {
    thread(env).pending = nil
}

@_cdecl("mead_jni_ExceptionCheck")
public func jni_ExceptionCheck(_ env: UnsafeMutableRawPointer) -> jboolean {
    thread(env).pending == nil ? 0 : 1
}

@_cdecl("mead_jni_FatalError")
public func jni_FatalError(_ env: UnsafeMutableRawPointer, _ message: UnsafePointer<CChar>?) {
    writeStandardError("mead(jni): FatalError: \(message.map { String(cString: $0) } ?? "")\n")
    abort()
}

// MARK: References

@_cdecl("mead_jni_PushLocalFrame")
public func jni_PushLocalFrame(_ env: UnsafeMutableRawPointer, _ capacity: jint) -> jint {
    thread(env).pushFrame()
    return jint(JNI_OK)
}

@_cdecl("mead_jni_PopLocalFrame")
public func jni_PopLocalFrame(_ env: UnsafeMutableRawPointer, _ result: OpaquePointer?) -> OpaquePointer? {
    let current = thread(env)
    let kept = current.resolve(result)
    current.popFrame()
    return current.newLocal(kept)
}

@_cdecl("mead_jni_NewGlobalRef")
public func jni_NewGlobalRef(_ env: UnsafeMutableRawPointer, _ object: OpaquePointer?) -> OpaquePointer? {
    guard let target = thread(env).resolve(object) else { return nil }
    let runtime = JavaRuntime.shared
    return runtime.lock.withLock {
        let (index, generation) = runtime.globals.insert(target)
        return Handle(kind: .global, index: index, generation: generation).pointer
    }
}

@_cdecl("mead_jni_DeleteGlobalRef")
public func jni_DeleteGlobalRef(_ env: UnsafeMutableRawPointer, _ object: OpaquePointer?) {
    guard let handle = Handle(object), handle.kind == .global else { return }
    let runtime = JavaRuntime.shared
    let removed = runtime.lock.withLock { runtime.globals.remove(at: handle.index, generation: handle.generation) }
    if !removed {
        runtime.problem("DeleteGlobalRef of a stale global reference")
    }
}

@_cdecl("mead_jni_NewWeakGlobalRef")
public func jni_NewWeakGlobalRef(_ env: UnsafeMutableRawPointer, _ object: OpaquePointer?) -> OpaquePointer? {
    guard let target = thread(env).resolve(object) else { return nil }
    let runtime = JavaRuntime.shared
    return runtime.lock.withLock {
        let (index, generation) = runtime.weaks.insert(target)
        return Handle(kind: .weak, index: index, generation: generation).pointer
    }
}

@_cdecl("mead_jni_DeleteWeakGlobalRef")
public func jni_DeleteWeakGlobalRef(_ env: UnsafeMutableRawPointer, _ object: OpaquePointer?) {
    guard let handle = Handle(object), handle.kind == .weak else { return }
    let runtime = JavaRuntime.shared
    let removed = runtime.lock.withLock { runtime.weaks.remove(at: handle.index, generation: handle.generation) }
    if !removed {
        runtime.problem("DeleteWeakGlobalRef of a stale weak reference")
    }
}

@_cdecl("mead_jni_DeleteLocalRef")
public func jni_DeleteLocalRef(_ env: UnsafeMutableRawPointer, _ object: OpaquePointer?) {
    guard let handle = Handle(object), handle.kind == .local else { return }
    thread(env).deleteLocal(handle)
}

@_cdecl("mead_jni_NewLocalRef")
public func jni_NewLocalRef(_ env: UnsafeMutableRawPointer, _ object: OpaquePointer?) -> OpaquePointer? {
    let current = thread(env)
    return current.newLocal(current.resolve(object))
}

@_cdecl("mead_jni_IsSameObject")
public func jni_IsSameObject(_ env: UnsafeMutableRawPointer, _ first: OpaquePointer?, _ second: OpaquePointer?) -> jboolean {
    let current = thread(env)
    return current.resolve(first) === current.resolve(second) ? 1 : 0
}

@_cdecl("mead_jni_EnsureLocalCapacity")
public func jni_EnsureLocalCapacity(_ env: UnsafeMutableRawPointer, _ capacity: jint) -> jint {
    jint(JNI_OK)
}

@_cdecl("mead_jni_GetObjectRefType")
public func jni_GetObjectRefType(_ env: UnsafeMutableRawPointer, _ object: OpaquePointer?) -> jobjectRefType {
    thread(env).referenceType(object)
}

// MARK: Objects and calls

private func allocate(_ definition: JavaClass) -> JavaObject {
    if definition.isSubclass(of: JavaRuntime.shared.existingClass(named: "java/lang/Throwable")!) {
        return JavaThrowable(javaClass: definition, message: nil)
    }
    if definition.swiftType != nil {
        JavaRuntime.shared.problem("AllocObject of \(definition.name), whose Swift class wants an initializer run")
    }
    return JavaObject(javaClass: definition)
}

@_cdecl("mead_jni_AllocObject")
public func jni_AllocObject(_ env: UnsafeMutableRawPointer, _ type: OpaquePointer?) -> OpaquePointer? {
    let current = thread(env)
    guard let definition = classOf(type, in: current) else { return nil }
    return current.newLocal(allocate(definition))
}

@_cdecl("mead_jni_new_object")
public func jni_new_object(_ env: UnsafeMutableRawPointer, _ type: OpaquePointer?, _ method: OpaquePointer?, _ arguments: UnsafePointer<jvalue>?) -> OpaquePointer? {
    let current = thread(env)
    guard let definition = classOf(type, in: current), let method else { return nil }
    let target = JavaMethod.from(method)
    if let constructor = target.constructor {
        do {
            let instance = try constructor(current, arguments)
            // A class with no constructors of its own, using its parent's.
            if instance.javaClass !== definition, definition.isSubclass(of: instance.javaClass) {
                instance.javaClass = definition
            }
            return current.newLocal(instance)
        } catch {
            current.raise(error)
            return nil
        }
    }
    let instance = allocate(definition)
    var ignored = jvalue()
    current.run(target, receiver: instance, arguments: arguments, result: &ignored)
    return current.pending == nil ? current.newLocal(instance) : nil
}

@_cdecl("mead_jni_method_shorty")
public func jni_method_shorty(_ method: OpaquePointer?) -> UnsafePointer<CChar>? {
    method.map { JavaMethod.from($0).shorty }
}

@_cdecl("mead_jni_invoke")
public func jni_invoke(_ env: UnsafeMutableRawPointer, _ mode: Int32, _ target: OpaquePointer?, _ method: OpaquePointer?, _ arguments: UnsafePointer<jvalue>?, _ result: UnsafeMutablePointer<jvalue>) {
    let current = thread(env)
    guard let method else {
        result.pointee = zero()
        JavaRuntime.shared.problem("a call through a null method ID")
        return
    }
    var chosen = JavaMethod.from(method)
    if mode == MEAD_JNI_STATIC {
        current.run(chosen, receiver: nil, arguments: arguments, result: result)
        return
    }
    guard let receiver = current.resolve(target) else {
        result.pointee = zero()
        current.raise("java/lang/NullPointerException", "\(chosen.name) on a null object")
        return
    }
    if mode == MEAD_JNI_VIRTUAL, chosen.owner !== receiver.javaClass,
       let override = receiver.javaClass.findMethod(MemberKey(name: chosen.name, signature: chosen.signature)) {
        chosen = override
    }
    current.run(chosen, receiver: receiver, arguments: arguments, result: result)
}

@_cdecl("mead_jni_GetMethodID")
public func jni_GetMethodID(_ env: UnsafeMutableRawPointer, _ type: OpaquePointer?, _ name: UnsafePointer<CChar>, _ signature: UnsafePointer<CChar>) -> OpaquePointer? {
    classOf(type, in: thread(env))?.method(named: String(cString: name), signature: String(cString: signature), isStatic: false)?.id
}

@_cdecl("mead_jni_GetStaticMethodID")
public func jni_GetStaticMethodID(_ env: UnsafeMutableRawPointer, _ type: OpaquePointer?, _ name: UnsafePointer<CChar>, _ signature: UnsafePointer<CChar>) -> OpaquePointer? {
    classOf(type, in: thread(env))?.method(named: String(cString: name), signature: String(cString: signature), isStatic: true)?.id
}

@_cdecl("mead_jni_GetFieldID")
public func jni_GetFieldID(_ env: UnsafeMutableRawPointer, _ type: OpaquePointer?, _ name: UnsafePointer<CChar>, _ signature: UnsafePointer<CChar>) -> OpaquePointer? {
    classOf(type, in: thread(env))?.field(named: String(cString: name), signature: String(cString: signature), isStatic: false)?.id
}

@_cdecl("mead_jni_GetStaticFieldID")
public func jni_GetStaticFieldID(_ env: UnsafeMutableRawPointer, _ type: OpaquePointer?, _ name: UnsafePointer<CChar>, _ signature: UnsafePointer<CChar>) -> OpaquePointer? {
    classOf(type, in: thread(env))?.field(named: String(cString: name), signature: String(cString: signature), isStatic: true)?.id
}

// MARK: Fields

@_cdecl("mead_jni_get_field")
public func jni_get_field(_ env: UnsafeMutableRawPointer, _ target: OpaquePointer?, _ field: OpaquePointer?, _ result: UnsafeMutablePointer<jvalue>) {
    let current = thread(env)
    guard let field else { return }
    let definition = JavaField.from(field)
    JavaRuntime.shared.trace("get \(definition.owner.name).\(definition.name)")
    let receiver = definition.isStatic ? nil : current.resolve(target)
    if !definition.isStatic, receiver == nil {
        current.raise("java/lang/NullPointerException", definition.name)
        return
    }
    if let getter = definition.getter {
        result.pointee = getter(current, receiver)
        return
    }
    let stored = JavaRuntime.shared.lock.withLock {
        definition.isStatic ? definition.staticValue : receiver!.storedFields[ObjectIdentifier(definition)]
    }
    switch stored {
    case let .primitive(value)?: result.pointee = value
    case let .reference(object)?: result.pointee.l = current.newLocal(object)
    case nil: break
    }
}

@_cdecl("mead_jni_set_field")
public func jni_set_field(_ env: UnsafeMutableRawPointer, _ target: OpaquePointer?, _ field: OpaquePointer?, _ value: UnsafePointer<jvalue>) {
    let current = thread(env)
    guard let field else { return }
    let definition = JavaField.from(field)
    JavaRuntime.shared.trace("set \(definition.owner.name).\(definition.name)")
    let receiver = definition.isStatic ? nil : current.resolve(target)
    if !definition.isStatic, receiver == nil {
        current.raise("java/lang/NullPointerException", definition.name)
        return
    }
    if let setter = definition.setter {
        setter(current, receiver, value.pointee)
        return
    }
    let stored: StoredValue = definition.isReference ? .reference(current.resolve(value.pointee.l)) : .primitive(value.pointee)
    JavaRuntime.shared.lock.withLock {
        if definition.isStatic {
            definition.staticValue = stored
        } else {
            receiver!.storedFields[ObjectIdentifier(definition)] = stored
        }
    }
}

// MARK: Strings

private func string(_ pointer: OpaquePointer?, in thread: JavaThread) -> JavaString? {
    thread.resolve(pointer) as? JavaString
}

/// Copies code units to C, NUL-terminated as a courtesy.
private func copyUnits(_ units: [UInt16]) -> UnsafePointer<jchar> {
    let copy = UnsafeMutablePointer<jchar>.allocate(capacity: units.count + 1)
    copy.initialize(from: units, count: units.count)
    copy[units.count] = 0
    return UnsafePointer(copy)
}

private func checkedRegion(_ start: jsize, _ length: jsize, of count: Int, in thread: JavaThread, _ exception: String) -> Bool {
    guard start >= 0, length >= 0, Int(start) + Int(length) <= count else {
        thread.raise(exception, "start \(start), length \(length) of \(count)")
        return false
    }
    return true
}

@_cdecl("mead_jni_NewString")
public func jni_NewString(_ env: UnsafeMutableRawPointer, _ units: UnsafePointer<jchar>?, _ length: jsize) -> OpaquePointer? {
    let contents = units.map { Array(UnsafeBufferPointer(start: $0, count: Int(length))) } ?? []
    return thread(env).newLocal(JavaString(units: contents))
}

@_cdecl("mead_jni_GetStringLength")
public func jni_GetStringLength(_ env: UnsafeMutableRawPointer, _ text: OpaquePointer?) -> jsize {
    jsize(string(text, in: thread(env))?.units.count ?? 0)
}

@_cdecl("mead_jni_GetStringChars")
public func jni_GetStringChars(_ env: UnsafeMutableRawPointer, _ text: OpaquePointer?, _ isCopy: UnsafeMutablePointer<jboolean>?) -> UnsafePointer<jchar>? {
    isCopy?.pointee = 1
    return string(text, in: thread(env)).map { copyUnits($0.units) }
}

@_cdecl("mead_jni_ReleaseStringChars")
public func jni_ReleaseStringChars(_ env: UnsafeMutableRawPointer, _ text: OpaquePointer?, _ units: UnsafePointer<jchar>?) {
    units?.deallocate()
}

@_cdecl("mead_jni_GetStringCritical")
public func jni_GetStringCritical(_ env: UnsafeMutableRawPointer, _ text: OpaquePointer?, _ isCopy: UnsafeMutablePointer<jboolean>?) -> UnsafePointer<jchar>? {
    jni_GetStringChars(env, text, isCopy)
}

@_cdecl("mead_jni_ReleaseStringCritical")
public func jni_ReleaseStringCritical(_ env: UnsafeMutableRawPointer, _ text: OpaquePointer?, _ units: UnsafePointer<jchar>?) {
    units?.deallocate()
}

@_cdecl("mead_jni_NewStringUTF")
public func jni_NewStringUTF(_ env: UnsafeMutableRawPointer, _ text: UnsafePointer<CChar>?) -> OpaquePointer? {
    guard let text else { return nil }
    return thread(env).newLocal(JavaString(units: ModifiedUTF8.decode(text)))
}

@_cdecl("mead_jni_GetStringUTFLength")
public func jni_GetStringUTFLength(_ env: UnsafeMutableRawPointer, _ text: OpaquePointer?) -> jsize {
    jsize(string(text, in: thread(env)).map { ModifiedUTF8.encode($0.units).count } ?? 0)
}

@_cdecl("mead_jni_GetStringUTFChars")
public func jni_GetStringUTFChars(_ env: UnsafeMutableRawPointer, _ text: OpaquePointer?, _ isCopy: UnsafeMutablePointer<jboolean>?) -> UnsafePointer<CChar>? {
    isCopy?.pointee = 1
    guard let contents = string(text, in: thread(env)) else { return nil }
    let bytes = ModifiedUTF8.encode(contents.units)
    let copy = malloc(bytes.count + 1)!.assumingMemoryBound(to: CChar.self)
    bytes.withUnsafeBytes { UnsafeMutableRawPointer(copy).copyMemory(from: $0.baseAddress ?? UnsafeRawPointer(copy), byteCount: bytes.count) }
    copy[bytes.count] = 0
    return UnsafePointer(copy)
}

@_cdecl("mead_jni_ReleaseStringUTFChars")
public func jni_ReleaseStringUTFChars(_ env: UnsafeMutableRawPointer, _ text: OpaquePointer?, _ bytes: UnsafePointer<CChar>?) {
    free(UnsafeMutablePointer(mutating: bytes))
}

@_cdecl("mead_jni_GetStringRegion")
public func jni_GetStringRegion(_ env: UnsafeMutableRawPointer, _ text: OpaquePointer?, _ start: jsize, _ length: jsize, _ buffer: UnsafeMutablePointer<jchar>) {
    let current = thread(env)
    guard let contents = string(text, in: current),
          checkedRegion(start, length, of: contents.units.count, in: current, "java/lang/StringIndexOutOfBoundsException") else { return }
    for offset in 0..<Int(length) {
        buffer[offset] = contents.units[Int(start) + offset]
    }
}

@_cdecl("mead_jni_GetStringUTFRegion")
public func jni_GetStringUTFRegion(_ env: UnsafeMutableRawPointer, _ text: OpaquePointer?, _ start: jsize, _ length: jsize, _ buffer: UnsafeMutablePointer<CChar>) {
    let current = thread(env)
    guard let contents = string(text, in: current),
          checkedRegion(start, length, of: contents.units.count, in: current, "java/lang/StringIndexOutOfBoundsException") else { return }
    let bytes = ModifiedUTF8.encode(contents.units[Int(start)..<Int(start + length)])
    for (offset, byte) in bytes.enumerated() {
        buffer[offset] = CChar(bitPattern: byte)
    }
    buffer[bytes.count] = 0
}

// MARK: Arrays

@_cdecl("mead_jni_GetArrayLength")
public func jni_GetArrayLength(_ env: UnsafeMutableRawPointer, _ array: OpaquePointer?) -> jsize {
    switch thread(env).resolve(array) {
    case let primitive as JavaPrimitiveArray: return jsize(primitive.count)
    case let objects as JavaObjectArray: return jsize(objects.elements.count)
    default: return 0
    }
}

@_cdecl("mead_jni_new_array")
public func jni_new_array(_ env: UnsafeMutableRawPointer, _ kind: CChar, _ length: jsize) -> OpaquePointer? {
    let current = thread(env)
    guard length >= 0 else {
        current.raise("java/lang/NegativeArraySizeException", "\(length)")
        return nil
    }
    let letter = UInt8(bitPattern: kind)
    let type = JavaRuntime.shared.findClass(named: "[" + String(UnicodeScalar(letter)))
    return current.newLocal(JavaPrimitiveArray(kind: letter, count: Int(length), type: type!))
}

@_cdecl("mead_jni_NewObjectArray")
public func jni_NewObjectArray(_ env: UnsafeMutableRawPointer, _ length: jsize, _ element: OpaquePointer?, _ initial: OpaquePointer?) -> OpaquePointer? {
    let current = thread(env)
    guard length >= 0 else {
        current.raise("java/lang/NegativeArraySizeException", "\(length)")
        return nil
    }
    guard let definition = classOf(element, in: current) else { return nil }
    let name = definition.name.hasPrefix("[") ? "[" + definition.name : "[L\(definition.name);"
    let type = JavaRuntime.shared.findClass(named: name)
    return current.newLocal(JavaObjectArray(count: Int(length), initial: current.resolve(initial), type: type!))
}

@_cdecl("mead_jni_GetObjectArrayElement")
public func jni_GetObjectArrayElement(_ env: UnsafeMutableRawPointer, _ array: OpaquePointer?, _ index: jsize) -> OpaquePointer? {
    let current = thread(env)
    guard let objects = current.resolve(array) as? JavaObjectArray,
          checkedRegion(index, 1, of: objects.elements.count, in: current, "java/lang/ArrayIndexOutOfBoundsException") else { return nil }
    return current.newLocal(objects.elements[Int(index)])
}

@_cdecl("mead_jni_SetObjectArrayElement")
public func jni_SetObjectArrayElement(_ env: UnsafeMutableRawPointer, _ array: OpaquePointer?, _ index: jsize, _ value: OpaquePointer?) {
    let current = thread(env)
    guard let objects = current.resolve(array) as? JavaObjectArray,
          checkedRegion(index, 1, of: objects.elements.count, in: current, "java/lang/ArrayIndexOutOfBoundsException") else { return }
    objects.elements[Int(index)] = current.resolve(value)
}

// Primitive arrays are pinned, never copied: the storage doesn't move. The
// array is kept alive between get and release in case the caller drops its
// reference to it in between, as JNI lets it.
@_cdecl("mead_jni_array_elements")
public func jni_array_elements(_ env: UnsafeMutableRawPointer, _ array: OpaquePointer?, _ isCopy: UnsafeMutablePointer<jboolean>?) -> UnsafeMutableRawPointer? {
    guard let primitive = thread(env).resolve(array) as? JavaPrimitiveArray else { return nil }
    isCopy?.pointee = 0
    _ = Unmanaged.passRetained(primitive)
    return primitive.storage
}

@_cdecl("mead_jni_array_release")
public func jni_array_release(_ env: UnsafeMutableRawPointer, _ array: OpaquePointer?, _ elements: UnsafeMutableRawPointer?, _ mode: jint) {
    // JNI_COMMIT keeps a copy alive and writes it back, which a pinned array
    // has no need of, and it does not end the pin.
    guard mode != jint(JNI_COMMIT), let primitive = thread(env).resolve(array) as? JavaPrimitiveArray else { return }
    Unmanaged.passUnretained(primitive).release()
}

@_cdecl("mead_jni_array_region")
public func jni_array_region(_ env: UnsafeMutableRawPointer, _ array: OpaquePointer?, _ start: jsize, _ length: jsize, _ buffer: UnsafeMutableRawPointer, _ write: jboolean) {
    let current = thread(env)
    guard let primitive = current.resolve(array) as? JavaPrimitiveArray,
          checkedRegion(start, length, of: primitive.count, in: current, "java/lang/ArrayIndexOutOfBoundsException") else { return }
    let size = primitive.elementSize
    let storage = primitive.storage + Int(start) * size
    if write != 0 {
        storage.copyMemory(from: buffer, byteCount: Int(length) * size)
    } else {
        buffer.copyMemory(from: storage, byteCount: Int(length) * size)
    }
}

// MARK: Natives, monitors, buffers

@_cdecl("mead_jni_RegisterNatives")
public func jni_RegisterNatives(_ env: UnsafeMutableRawPointer, _ type: OpaquePointer?, _ methods: UnsafePointer<JNINativeMethod>?, _ count: jint) -> jint {
    let current = thread(env)
    guard let definition = classOf(type, in: current), let methods else { return jint(JNI_ERR) }
    let runtime = JavaRuntime.shared
    runtime.lock.withLock {
        for index in 0..<Int(count) {
            let entry = methods[index]
            let name = String(cString: entry.name)
            let signature = String(cString: entry.signature)
            let key = MemberKey(name: name, signature: signature)
            // A native method is declared by Java code mead does not have.
            // Whether it is static will show in how it is looked up.
            let method: JavaMethod
            if let existing = definition.methods[key] {
                method = existing
            } else {
                method = JavaMethod(name: name, signature: signature, isStatic: false, owner: definition, isSynthesized: true)
                definition.methods[key] = method
            }
            method.native = entry.fnPtr
            method.everRegistered = true
            runtime.trace("registered \(definition.name).\(name)\(signature)")
        }
    }
    return jint(JNI_OK)
}

@_cdecl("mead_jni_UnregisterNatives")
public func jni_UnregisterNatives(_ env: UnsafeMutableRawPointer, _ type: OpaquePointer?) -> jint {
    guard let definition = classOf(type, in: thread(env)) else { return jint(JNI_ERR) }
    JavaRuntime.shared.lock.withLock {
        for method in definition.methods.values {
            method.native = nil
        }
    }
    return jint(JNI_OK)
}

private func monitor(of object: JavaObject) -> JavaLock {
    JavaRuntime.shared.lock.withLock {
        if let existing = object.monitor {
            return existing
        }
        let created = JavaLock()
        object.monitor = created
        return created
    }
}

@_cdecl("mead_jni_MonitorEnter")
public func jni_MonitorEnter(_ env: UnsafeMutableRawPointer, _ object: OpaquePointer?) -> jint {
    guard let target = thread(env).resolve(object) else { return jint(JNI_ERR) }
    monitor(of: target).lock()
    return jint(JNI_OK)
}

@_cdecl("mead_jni_MonitorExit")
public func jni_MonitorExit(_ env: UnsafeMutableRawPointer, _ object: OpaquePointer?) -> jint {
    guard let target = thread(env).resolve(object) else { return jint(JNI_ERR) }
    monitor(of: target).unlock()
    return jint(JNI_OK)
}

@_cdecl("mead_jni_NewDirectByteBuffer")
public func jni_NewDirectByteBuffer(_ env: UnsafeMutableRawPointer, _ address: UnsafeMutableRawPointer?, _ capacity: jlong) -> OpaquePointer? {
    thread(env).newLocal(JavaDirectBuffer(address: address, capacity: capacity))
}

@_cdecl("mead_jni_GetDirectBufferAddress")
public func jni_GetDirectBufferAddress(_ env: UnsafeMutableRawPointer, _ buffer: OpaquePointer?) -> UnsafeMutableRawPointer? {
    (thread(env).resolve(buffer) as? JavaDirectBuffer)?.address
}

@_cdecl("mead_jni_GetDirectBufferCapacity")
public func jni_GetDirectBufferCapacity(_ env: UnsafeMutableRawPointer, _ buffer: OpaquePointer?) -> jlong {
    (thread(env).resolve(buffer) as? JavaDirectBuffer)?.capacity ?? -1
}

// MARK: The VM

@_cdecl("mead_jni_GetJavaVM")
public func jni_GetJavaVM(_ env: UnsafeMutableRawPointer, _ vm: UnsafeMutablePointer<UnsafeMutablePointer<JavaVM?>?>) -> jint {
    vm.pointee = javaVM
    return jint(JNI_OK)
}

@_cdecl("mead_jni_DestroyJavaVM")
public func jni_DestroyJavaVM(_ vm: UnsafeMutableRawPointer) -> jint {
    jint(JNI_OK) // the VM is the process's, and goes with it
}

private func attach(_ env: UnsafeMutablePointer<UnsafeMutablePointer<JNIEnv?>?>?) -> jint {
    env?.pointee = JavaRuntime.shared.attachCurrentThread().env
    return jint(JNI_OK)
}

@_cdecl("mead_jni_AttachCurrentThread")
public func jni_AttachCurrentThread(_ vm: UnsafeMutableRawPointer, _ env: UnsafeMutablePointer<UnsafeMutablePointer<JNIEnv?>?>?, _ arguments: UnsafeMutableRawPointer?) -> jint {
    attach(env)
}

@_cdecl("mead_jni_AttachCurrentThreadAsDaemon")
public func jni_AttachCurrentThreadAsDaemon(_ vm: UnsafeMutableRawPointer, _ env: UnsafeMutablePointer<UnsafeMutablePointer<JNIEnv?>?>?, _ arguments: UnsafeMutableRawPointer?) -> jint {
    attach(env)
}

@_cdecl("mead_jni_DetachCurrentThread")
public func jni_DetachCurrentThread(_ vm: UnsafeMutableRawPointer) -> jint {
    JavaRuntime.shared.detachCurrentThread()
    return jint(JNI_OK)
}

@_cdecl("mead_jni_GetEnv")
public func jni_GetEnv(_ vm: UnsafeMutableRawPointer, _ env: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ version: jint) -> jint {
    let supported = [JNI_VERSION_1_1, JNI_VERSION_1_2, JNI_VERSION_1_4, JNI_VERSION_1_6].map(jint.init)
    guard supported.contains(version) else {
        env.pointee = nil
        return jint(JNI_EVERSION)
    }
    guard let thread = JavaRuntime.shared.currentThread else {
        env.pointee = nil
        return jint(JNI_EDETACHED)
    }
    env.pointee = UnsafeMutableRawPointer(thread.block)
    return jint(JNI_OK)
}

// MARK: The library's own entry points

@_cdecl("JNI_GetCreatedJavaVMs")
public func JNI_GetCreatedJavaVMs(_ vms: UnsafeMutablePointer<UnsafeMutablePointer<JavaVM?>?>?, _ capacity: jsize, _ count: UnsafeMutablePointer<jsize>?) -> jint {
    JavaRuntime.shared.start()
    if capacity > 0 {
        vms?[0] = javaVM
    }
    count?.pointee = 1
    return jint(JNI_OK)
}

@_cdecl("JNI_CreateJavaVM")
public func JNI_CreateJavaVM(_ vm: UnsafeMutablePointer<UnsafeMutablePointer<JavaVM?>?>?, _ env: UnsafeMutablePointer<UnsafeMutablePointer<JNIEnv?>?>?, _ arguments: UnsafeMutableRawPointer?) -> jint {
    vm?.pointee = javaVM
    return attach(env)
}

@_cdecl("JNI_GetDefaultJavaVMInitArgs")
public func JNI_GetDefaultJavaVMInitArgs(_ arguments: UnsafeMutableRawPointer?) -> jint {
    jint(JNI_OK)
}
