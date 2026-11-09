import Glibc
import MeadJNI
import MeadJava

/// Unity's bridge from Java interfaces to native code (bitter.jnibridge).
/// newInterfaceProxy makes an object implementing the interfaces whose
/// every call goes to libunity's native JNIBridge.invoke, with the
/// engine's pointer, the method's interface, the method, and the arguments
/// boxed; disableInterfaceProxy cuts it off. Unity paces its frames this
/// way (a Choreographer.FrameCallback), and listens for audio focus and
/// input devices.
@JavaClass("bitter/jnibridge/JNIBridge")
public final class JavaJNIBridge: JavaObject {
    private static let invokeSignature = "(JLjava/lang/Class;Ljava/lang/reflect/Method;[Ljava/lang/Object;)Ljava/lang/Object;"

    /// A proxy's engine pointer: 0 once disabled.
    final class Target {
        let lock = LockedValue<Int64>(0)
        init(_ pointer: Int64) { lock.withLock { $0 = pointer } }
    }

    private static let targets = LockedValue([ObjectIdentifier: Target]())

    @JavaMethod("newInterfaceProxy", signature: "(J[Ljava/lang/Class;)Ljava/lang/Object;")
    public static func newInterfaceProxy(_ pointer: Int64, _ interfaces: JavaObject?) -> JavaObject? {
        let classes = (interfaces as? JavaObjectArray)?.elements.compactMap { $0 as? JavaClass } ?? []
        let target = Target(pointer)
        let proxy = JavaProxy(interfaces: classes) { thread, method, arguments in
            invoke(target: target, thread: thread, method: method, arguments: arguments)
        }
        targets.withLock { $0[ObjectIdentifier(proxy)] = target }
        return proxy
    }

    @JavaMethod("disableInterfaceProxy", signature: "(Ljava/lang/Object;)V")
    public static func disableInterfaceProxy(_ proxy: JavaObject?) {
        guard let proxy else { return }
        targets.withLock { $0[ObjectIdentifier(proxy)] }?.lock.withLock { $0 = 0 }
    }

    /// What Java's proxy handler does: box, call the engine, unbox.
    static func invoke(target: Target, thread: JavaThread, method: JavaMethod, arguments: UnsafePointer<jvalue>?) -> jvalue {
        // Read once: Java's handler holds a reentrant lock across the call,
        // which an engine calling back into the same proxy would need.
        let pointer = target.lock.withLock { $0 }
        guard pointer != 0 else { return jvalue() }
        let types = method.parameterTypes
        thread.pushFrame()
        let boxed = JavaRuntime.shared.newObjectArray(elementClass: "java/lang/Object", count: 0) as? JavaObjectArray
        boxed?.elements = types.enumerated().map { index, type in box(arguments![index], as: type, in: thread) }
        var values = [jvalue](repeating: jvalue(), count: 4)
        values[0].j = pointer
        values[1].l = thread.newLocal(method.owner)
        values[2].l = thread.newLocal(JavaReflectedMethod(method: method))
        values[3].l = thread.newLocal(boxed)
        let returned = thread.call("bitter/jnibridge/JNIBridge", "invoke", invokeSignature, isStatic: true, on: nil, values)
        let object = thread.resolve(returned.l)
        thread.popFrame()
        // The caller's frame holds what's returned.
        return unbox(object, as: method.returnType, in: thread)
    }

    static func box(_ value: jvalue, as type: String, in thread: JavaThread) -> JavaObject? {
        switch type {
        case "Z": return JavaBoolean(value: value.z != 0)
        case "B": return JavaInteger(value: Int32(value.b))
        case "C": return JavaInteger(value: Int32(value.c))
        case "S": return JavaInteger(value: Int32(value.s))
        case "I": return JavaInteger(value: value.i)
        case "J": return JavaLong(value: value.j)
        case "F": return JavaFloat(value: value.f)
        case "D": return JavaDouble(value: value.d)
        default: return thread.resolve(value.l)
        }
    }

    static func unbox(_ object: JavaObject?, as type: String, in thread: JavaThread) -> jvalue {
        var value = jvalue()
        switch (type, object) {
        case ("V", _): break
        case ("Z", let boolean as JavaBoolean): value.z = boolean.value ? 1 : 0
        case ("I", let integer as JavaInteger): value.i = integer.value
        case ("J", let long as JavaLong): value.j = long.value
        case ("J", let integer as JavaInteger): value.j = Int64(integer.value)
        case ("F", let float as JavaFloat): value.f = float.value
        case ("D", let double as JavaDouble): value.d = double.value
        case ("B", let integer as JavaInteger): value.b = Int8(truncatingIfNeeded: integer.value)
        case ("C", let integer as JavaInteger): value.c = UInt16(truncatingIfNeeded: integer.value)
        case ("S", let integer as JavaInteger): value.s = Int16(truncatingIfNeeded: integer.value)
        case (let type, _) where type.hasPrefix("L") || type.hasPrefix("["): value.l = thread.newLocal(object)
        default: break
        }
        return value
    }
}
