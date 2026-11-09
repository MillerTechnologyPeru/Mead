import Glibc

/// An object made at run time to implement interfaces, as
/// java.lang.reflect.Proxy makes one: every call of an instance method on
/// it, through JNI or from Swift, goes to its handler, which gets the
/// method called and the call's arguments.
public final class JavaProxy: JavaObject {
    public typealias Handler = (_ thread: JavaThread, _ method: JavaMethod, _ arguments: UnsafePointer<jvalue>?) -> jvalue

    let handler: Handler

    public init(interfaces: [JavaClass], handler: @escaping Handler) {
        self.handler = handler
        super.init(javaClass: Self.proxyClass(for: interfaces))
    }

    nonisolated(unsafe) private static var classes: [String: JavaClass] = [:]

    /// One class per set of interfaces, as Java makes: $Proxy0, $Proxy1, ...
    private static func proxyClass(for interfaces: [JavaClass]) -> JavaClass {
        let runtime = JavaRuntime.shared
        runtime.start()
        let key = interfaces.map(\.name).joined(separator: ",")
        return runtime.lock.withLock {
            if let existing = classes[key] {
                return existing
            }
            let definition = JavaClass(name: "$Proxy\(classes.count)", superclass: runtime.classesByName["java/lang/Object"],
                                       swiftType: nil, isSynthesized: false)
            definition.javaClass = runtime.classesByName["java/lang/Class"]
            definition.interfaces = interfaces
            classes[key] = definition
            return definition
        }
    }
}

extension JavaMethod {
    /// The signature's parameter types, one descriptor each: "J",
    /// "Ljava/lang/String;", "[I".
    public var parameterTypes: [String] {
        let bytes = Array(signature.utf8)
        guard bytes.first == UInt8(ascii: "(") else { return [] }
        var types: [String] = []
        var index = 1
        while index < bytes.count, bytes[index] != UInt8(ascii: ")") {
            let start = index
            while index < bytes.count, bytes[index] == UInt8(ascii: "[") { index += 1 }
            if index < bytes.count, bytes[index] == UInt8(ascii: "L") {
                while index < bytes.count, bytes[index] != UInt8(ascii: ";") { index += 1 }
            }
            index += 1
            types.append(String(decoding: bytes[start..<min(index, bytes.count)], as: UTF8.self))
        }
        return types
    }

    /// The return type's descriptor: "V", "Z", "Ljava/lang/Object;".
    public var returnType: String {
        guard let close = signature.lastIndex(of: ")") else { return "V" }
        return String(signature[signature.index(after: close)...])
    }
}

/// java.lang.reflect.Method, as a proxy's handler is given one and as
/// ToReflectedMethod makes one.
@JavaClass("java/lang/reflect/Method")
public final class JavaReflectedMethod: JavaObject {
    public let method: JavaMethod

    public init(method: JavaMethod) {
        self.method = method
        super.init()
    }

    @JavaMethod("getName") public func getName() -> String? { method.name }
    @JavaMethod("getDeclaringClass") public func getDeclaringClass() -> JavaClass? { method.owner }
    @JavaMethod("isDefault") public func isDefault() -> Bool { false }

    @JavaMethod("getParameterTypes", signature: "()[Ljava/lang/Class;")
    public func getParameterTypes() -> JavaObject? {
        let runtime = JavaRuntime.shared
        guard let array = runtime.newObjectArray(elementClass: "java/lang/Class", count: 0) as? JavaObjectArray else { return nil }
        array.elements = method.parameterTypes.map { runtime.classForDescriptor($0) }
        return array
    }

    @JavaMethod("getReturnType", signature: "()Ljava/lang/Class;")
    public func getReturnType() -> JavaClass? { JavaRuntime.shared.classForDescriptor(method.returnType) }

    @JavaMethod("toString") public func javaToString() -> String? {
        "\(method.owner.name.replacingSlashes()).\(method.name)\(method.signature)"
    }
}

extension JavaRuntime {
    /// The class a type descriptor names: a class's or an array's, or for a
    /// primitive one named as Java names it ("int", "long", ...).
    func classForDescriptor(_ descriptor: String) -> JavaClass? {
        let primitives = ["Z": "boolean", "B": "byte", "C": "char", "S": "short", "I": "int", "J": "long", "F": "float",
                          "D": "double", "V": "void"]
        if let primitive = primitives[descriptor] {
            return findClass(named: primitive)
        }
        if descriptor.hasPrefix("L"), descriptor.hasSuffix(";") {
            return findClass(named: String(descriptor.dropFirst().dropLast()))
        }
        return findClass(named: descriptor)
    }
}
