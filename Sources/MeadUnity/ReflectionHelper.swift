import MeadJNI
import MeadJava

/// com.unity3d.player.ReflectionHelper: how Unity's C# AndroidJavaObject and
/// AndroidJavaProxy reach Java. Lookups answer with reflection objects that
/// FromReflectedMethod and FromReflectedField turn into IDs, and a proxy's
/// calls go to libunity's native nativeProxyInvoke, by method name.
@JavaClass("com/unity3d/player/ReflectionHelper")
public final class JavaUnityReflectionHelper: JavaObject {
    private static let invokeSignature = "(JLjava/lang/String;[Ljava/lang/Object;)Ljava/lang/Object;"

    @JavaMethod("getMethodID", signature: "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/String;Z)Ljava/lang/reflect/Method;")
    public static func getMethodID(_ type: JavaObject?, _ name: String?, _ signature: String?, _ isStatic: Bool) -> JavaReflectedMethod? {
        guard let type = type as? JavaClass, let name, let signature else { return nil }
        return type.reflectedMethod(named: name, signature: signature, isStatic: isStatic)
    }

    @JavaMethod("getConstructorID", signature: "(Ljava/lang/Class;Ljava/lang/String;)Ljava/lang/reflect/Constructor;")
    public static func getConstructorID(_ type: JavaObject?, _ signature: String?) -> JavaReflectedMethod? {
        guard let type = type as? JavaClass, let signature else { return nil }
        return type.reflectedMethod(named: "<init>", signature: signature, isStatic: false)
    }

    @JavaMethod("getFieldID", signature: "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/String;Z)Ljava/lang/reflect/Field;")
    public static func getFieldID(_ type: JavaObject?, _ name: String?, _ signature: String?, _ isStatic: Bool) -> JavaReflectedField? {
        guard let type = type as? JavaClass, let name else { return nil }
        return type.reflectedField(named: name, signature: signature ?? "", isStatic: isStatic)
    }

    @JavaMethod("getFieldSignature", signature: "(Ljava/lang/reflect/Field;)Ljava/lang/String;")
    public static func getFieldSignature(_ field: JavaObject?) -> String? {
        (field as? JavaReflectedField)?.field.signature
    }

    @JavaMethod("newProxyInstance", signature: "(Lcom/unity3d/player/UnityPlayer;JLjava/lang/Class;)Ljava/lang/Object;")
    public static func newProxyInstance(_ player: JavaObject?, _ pointer: Int64, _ interface: JavaObject?) -> JavaObject? {
        proxy(pointer, [interface as? JavaClass].compactMap { $0 })
    }

    @JavaMethod("newProxyInstance", signature: "(Lcom/unity3d/player/UnityPlayer;J[Ljava/lang/Class;)Ljava/lang/Object;")
    public static func newProxyInstance(_ player: JavaObject?, _ pointer: Int64, interfaces: JavaObject?) -> JavaObject? {
        proxy(pointer, (interfaces as? JavaObjectArray)?.elements.compactMap { $0 as? JavaClass } ?? [])
    }

    private static func proxy(_ pointer: Int64, _ interfaces: [JavaClass]) -> JavaObject {
        JavaProxy(interfaces: interfaces) { thread, method, arguments in
            thread.pushFrame()
            let boxed = JavaRuntime.shared.newObjectArray(elementClass: "java/lang/Object", count: 0) as? JavaObjectArray
            boxed?.elements = method.parameterTypes.enumerated().map { index, type in
                JavaJNIBridge.box(arguments![index], as: type, in: thread)
            }
            var values = [jvalue](repeating: jvalue(), count: 3)
            values[0].j = pointer
            values[1].l = thread.newLocal(JavaString(method.name))
            values[2].l = thread.newLocal(boxed)
            let returned = thread.call("com/unity3d/player/ReflectionHelper", "nativeProxyInvoke", invokeSignature, isStatic: true, on: nil, values)
            let object = thread.resolve(returned.l)
            thread.popFrame()
            return JavaJNIBridge.unbox(object, as: method.returnType, in: thread)
        }
    }
}
