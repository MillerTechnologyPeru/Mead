import Glibc

/// One thing a class has, as a Swift class declares it. `@JavaClass` writes
/// these; they can be written by hand too.
public enum JavaMember {
    public typealias MethodBody = (JavaThread, JavaObject?, UnsafePointer<jvalue>?) throws -> jvalue
    public typealias ConstructorBody = (JavaThread, UnsafePointer<jvalue>?) throws -> JavaObject
    public typealias Getter = (JavaThread, JavaObject?) -> jvalue
    public typealias Setter = (JavaThread, JavaObject?, jvalue) -> Void

    case method(name: String, signature: String, isStatic: Bool, body: MethodBody)
    case constructor(signature: String, body: ConstructorBody)
    case field(name: String, signature: String, isStatic: Bool, get: Getter, set: Setter)
}

/// A java/lang/Object, and what every Java object is a kind of.
open class JavaObject {
    open class var javaClassName: String { "java/lang/Object" }
    open class var javaSuperclassType: JavaObject.Type? { nil }
    open class var javaInterfaceNames: [String] { [] }

    open class func javaMembers() -> [JavaMember] {
        [
            .method(name: "hashCode", signature: "()I", isStatic: false) { _, receiver, _ in
                var value = jvalue()
                value.i = Int32(truncatingIfNeeded: ObjectIdentifier(receiver!).hashValue)
                return value
            },
            .method(name: "equals", signature: "(Ljava/lang/Object;)Z", isStatic: false) { thread, receiver, arguments in
                var value = jvalue()
                value.z = receiver === thread.resolve(arguments![0].l) ? 1 : 0
                return value
            },
            .method(name: "toString", signature: "()Ljava/lang/String;", isStatic: false) { thread, receiver, _ in
                let text = "\(receiver!.javaClass.name.replacingSlashes())@\(UInt(bitPattern: ObjectIdentifier(receiver!).hashValue))"
                var value = jvalue()
                value.l = thread.newLocal(JavaString(text))
                return value
            },
            .method(name: "getClass", signature: "()Ljava/lang/Class;", isStatic: false) { thread, receiver, _ in
                var value = jvalue()
                value.l = thread.newLocal(receiver!.javaClass)
                return value
            },
        ]
    }

    /// The object's class. Only ever nil during the start of the world.
    public internal(set) var javaClass: JavaClass!

    /// The values of fields no Swift property backs.
    var storedFields: [ObjectIdentifier: StoredValue] = [:]
    var monitor: JavaLock?

    public init() {
        javaClass = JavaRuntime.shared.defineClass(for: type(of: self))
    }

    init(javaClass: JavaClass?) {
        self.javaClass = javaClass
    }
}

extension String {
    func replacingSlashes() -> String {
        String(map { $0 == "/" ? "." : $0 })
    }
}

enum StoredValue {
    case primitive(jvalue)
    case reference(JavaObject?)
}

public final class JavaMethod {
    public let name: String
    public let signature: String
    public internal(set) var isStatic: Bool
    public unowned let owner: JavaClass
    public let isSynthesized: Bool
    let shorty: UnsafePointer<CChar>
    let returnsReference: Bool
    var body: JavaMember.MethodBody?
    var constructor: JavaMember.ConstructorBody?
    var native: UnsafeMutableRawPointer?
    var everRegistered = false

    init(name: String, signature: String, isStatic: Bool, owner: JavaClass, isSynthesized: Bool) {
        self.name = name
        self.signature = signature
        self.isStatic = isStatic
        self.owner = owner
        self.isSynthesized = isSynthesized
        let parsed = shortyOf(signature)
        shorty = UnsafePointer(strdup(parsed)!)
        returnsReference = parsed.first == "L"
    }

    var id: OpaquePointer {
        OpaquePointer(Unmanaged.passUnretained(self).toOpaque())
    }

    /// The method a jmethodID names. IDs live as long as the process.
    static func from(_ id: OpaquePointer) -> JavaMethod {
        Unmanaged<JavaMethod>.fromOpaque(UnsafeRawPointer(id)).takeUnretainedValue()
    }
}

public final class JavaField {
    public let name: String
    public let signature: String
    public let isStatic: Bool
    public unowned let owner: JavaClass
    public let isSynthesized: Bool
    let getter: JavaMember.Getter?
    let setter: JavaMember.Setter?
    var staticValue: StoredValue?

    init(name: String, signature: String, isStatic: Bool, owner: JavaClass, isSynthesized: Bool,
         getter: JavaMember.Getter? = nil, setter: JavaMember.Setter? = nil) {
        self.name = name
        self.signature = signature
        self.isStatic = isStatic
        self.owner = owner
        self.isSynthesized = isSynthesized
        self.getter = getter
        self.setter = setter
    }

    var isReference: Bool {
        signature.hasPrefix("L") || signature.hasPrefix("[")
    }

    var id: OpaquePointer {
        OpaquePointer(Unmanaged.passUnretained(self).toOpaque())
    }

    static func from(_ id: OpaquePointer) -> JavaField {
        Unmanaged<JavaField>.fromOpaque(UnsafeRawPointer(id)).takeUnretainedValue()
    }
}

/// The return type's letter, then each argument's, with L for any reference.
func shortyOf(_ signature: String) -> String {
    let bytes = Array(signature.utf8)
    var index = bytes.first == UInt8(ascii: "(") ? 1 : 0
    var arguments = ""

    func next() -> Character {
        var array = false
        while index < bytes.count, bytes[index] == UInt8(ascii: "[") {
            array = true
            index += 1
        }
        guard index < bytes.count else { return "V" }
        let letter = Character(UnicodeScalar(bytes[index]))
        if letter == "L" {
            while index < bytes.count, bytes[index] != UInt8(ascii: ";") {
                index += 1
            }
        }
        index += 1
        return array || letter == "L" ? "L" : letter
    }

    while index < bytes.count, bytes[index] != UInt8(ascii: ")") {
        arguments.append(next())
    }
    index += 1
    return String(next()) + arguments
}

/// A class: java/lang/Class's instances, and the registry's entries.
public final class JavaClass: JavaObject {
    public override class var javaClassName: String { "java/lang/Class" }
    public override class var javaSuperclassType: JavaObject.Type? { JavaObject.self }
    public override class func javaMembers() -> [JavaMember] {
        [
            .method(name: "getClassLoader", signature: "()Ljava/lang/ClassLoader;", isStatic: false) { thread, _, _ in
                var value = jvalue()
                value.l = thread.newLocal(JavaRuntime.shared.classLoaderFactory?())
                return value
            },
            .method(name: "getName", signature: "()Ljava/lang/String;", isStatic: false) { thread, receiver, _ in
                var value = jvalue()
                value.l = thread.newLocal(JavaString((receiver as! JavaClass).name.replacingSlashes()))
                return value
            },
            // What FindClass would give for the same name, as Java writes it,
            // with dots: Unity finds every class it uses this way.
            .method(name: "forName", signature: "(Ljava/lang/String;)Ljava/lang/Class;", isStatic: true) { thread, _, arguments in
                try forName(thread, arguments)
            },
            .method(name: "forName", signature: "(Ljava/lang/String;ZLjava/lang/ClassLoader;)Ljava/lang/Class;",
                    isStatic: true) { thread, _, arguments in
                try forName(thread, arguments)
            },
        ]
    }

    private static func forName(_ thread: JavaThread, _ arguments: UnsafePointer<jvalue>?) throws -> jvalue {
        guard let name = (thread.resolve(arguments?[0].l) as? JavaString)?.swiftValue else {
            throw JavaException("java/lang/NullPointerException", "Class.forName(null)")
        }
        var value = jvalue()
        value.l = thread.newLocal(JavaRuntime.shared.findClassPublic(named: String(name.map { $0 == "." ? "/" : $0 })))
        return value
    }

    public let name: String
    public private(set) var superclass: JavaClass?
    public let isSynthesized: Bool
    public internal(set) var isInterface = false
    public internal(set) var interfaces: [JavaClass] = []
    let swiftType: JavaObject.Type?
    var methods: [MemberKey: JavaMethod] = [:]
    var fields: [MemberKey: JavaField] = [:]

    init(name: String, superclass: JavaClass?, swiftType: JavaObject.Type?, isSynthesized: Bool) {
        self.name = name
        self.superclass = superclass
        self.swiftType = swiftType
        self.isSynthesized = isSynthesized
        super.init(javaClass: nil)
    }

    func add(_ member: JavaMember) {
        switch member {
        case let .method(name, signature, isStatic, body):
            let method = JavaMethod(name: name, signature: signature, isStatic: isStatic, owner: self, isSynthesized: false)
            method.body = body
            methods[MemberKey(name: name, signature: signature)] = method
        case let .constructor(signature, body):
            let method = JavaMethod(name: "<init>", signature: signature, isStatic: false, owner: self, isSynthesized: false)
            method.constructor = body
            methods[MemberKey(name: "<init>", signature: signature)] = method
        case let .field(name, signature, isStatic, get, set):
            fields[MemberKey(name: name, signature: signature)] =
                JavaField(name: name, signature: signature, isStatic: isStatic, owner: self, isSynthesized: false, getter: get, setter: set)
        }
    }

    // These take the lock because another thread's GetMethodID can be adding
    // a stand-in to the same table while a virtual call looks through it.
    func findMethod(_ key: MemberKey) -> JavaMethod? {
        JavaRuntime.shared.lock.withLock {
            var current: JavaClass? = self
            while let at = current {
                if let found = at.methods[key] {
                    return found
                }
                current = at.superclass
            }
            // Only then what interfaces declare: a real method always wins.
            current = self
            while let at = current {
                for interface in at.interfaces {
                    if let found = interface.findMethod(key) {
                        return found
                    }
                }
                current = at.superclass
            }
            return nil
        }
    }

    /// Whether a native library has registered this method: how a caller
    /// tells which version of a library it has, when natives change shape.
    public func hasNativeMethod(named name: String, signature: String) -> Bool {
        findMethod(MemberKey(name: name, signature: signature))?.everRegistered == true
    }

    private func realObjectField(named name: String, isStatic: Bool) -> JavaField? {
        var current: JavaClass? = self
        while let at = current {
            if let match = at.fields.values.first(where: { $0.name == name && $0.isStatic == isStatic && !$0.isSynthesized && $0.isReference }) {
                return match
            }
            current = at.superclass
        }
        return nil
    }

    func findField(_ key: MemberKey) -> JavaField? {
        JavaRuntime.shared.lock.withLock {
            var current: JavaClass? = self
            while let at = current {
                if let found = at.fields[key] {
                    return found
                }
                current = at.superclass
            }
            return nil
        }
    }

    public func isSubclass(of other: JavaClass) -> Bool {
        var current: JavaClass? = self
        while let at = current {
            if at === other || at.interfaces.contains(where: { $0.isSubclass(of: other) }) {
                return true
            }
            current = at.superclass
        }
        return false
    }

    /// The method a GetMethodID names: a real one, or a stand-in returning
    /// zero, recorded for the stub writer.
    func method(named name: String, signature: String, isStatic: Bool) -> JavaMethod? {
        let runtime = JavaRuntime.shared
        runtime.trace("\(isStatic ? "GetStaticMethodID" : "GetMethodID") \(self.name).\(name)\(signature)")
        let key = MemberKey(name: name, signature: signature)
        let existing: JavaMethod? = runtime.lock.withLock {
            guard let found = findMethod(key) else { return nil }
            if found.isStatic == isStatic {
                return found
            }
            // RegisterNatives could not know: the first lookup settles it.
            if found.everRegistered {
                found.isStatic = isStatic
                return found
            }
            return nil
        }
        if let existing {
            return existing
        }
        // Looked for outside the lock: the loader's lock is the other way
        // round, when an initializer calls into JNI.
        let native = runtime.boundNative(owner: self.name, name: name, signature: signature)
        return runtime.lock.withLock {
            if native == nil {
                runtime.problemOnce("\(self.name).\(name)\(signature) is not implemented")
            }
            let method = JavaMethod(name: name, signature: signature, isStatic: isStatic, owner: self, isSynthesized: true)
            method.native = native
            method.everRegistered = native != nil
            methods[key] = method
            return method
        }
    }

    func field(named name: String, signature: String, isStatic: Bool) -> JavaField? {
        let runtime = JavaRuntime.shared
        runtime.trace("\(isStatic ? "GetStaticFieldID" : "GetFieldID") \(self.name).\(name) \(signature)")
        return runtime.lock.withLock {
            let key = MemberKey(name: name, signature: signature)
            if let found = findField(key), found.isStatic == isStatic {
                return found
            }
            // Unity's C# knows a field it gets as an object only as Object.
            if signature == "Ljava/lang/Object;", let real = realObjectField(named: name, isStatic: isStatic) {
                return real
            }
            runtime.problemOnce("field \(self.name).\(name) \(signature) is not implemented")
            let field = JavaField(name: name, signature: signature, isStatic: isStatic, owner: self, isSynthesized: true)
            fields[key] = field
            return field
        }
    }
}

/// A java/lang/Throwable.
@JavaClass("java/lang/Throwable")
open class JavaThrowable: JavaObject {
    public var message: String?

    @JavaMethod("<init>", signature: "()V")
    public override init() {
        message = nil
        super.init()
    }

    @JavaMethod("<init>", signature: "(Ljava/lang/String;)V")
    public init(_ message: String?) {
        self.message = message
        super.init()
    }

    init(javaClass: JavaClass, message: String?) {
        self.message = message
        super.init(javaClass: javaClass)
    }

    @JavaMethod("getMessage")
    public func getMessage() -> String? {
        message
    }

    @JavaMethod("toString")
    public func describe() -> String? {
        let name = javaClass.name.replacingSlashes()
        return message.map { "\(name): \($0)" } ?? name
    }
}

/// A Swift error carrying a Java exception out to the JNI caller.
public struct JavaException: Error {
    public let throwable: JavaThrowable

    public init(_ throwable: JavaThrowable) {
        self.throwable = throwable
    }

    /// An exception of the named class with a message.
    public init(_ className: String, _ message: String?) {
        let runtime = JavaRuntime.shared
        let type = runtime.existingClass(named: className) ?? runtime.existingClass(named: "java/lang/Throwable")!
        throwable = JavaThrowable(javaClass: type, message: message)
    }
}

/// A java/nio/DirectByteBuffer: memory the native side owns.
@JavaClass("java/nio/DirectByteBuffer")
public final class JavaDirectBuffer: JavaObject {
    let address: UnsafeMutableRawPointer?
    let capacity: Int64

    init(address: UnsafeMutableRawPointer?, capacity: Int64) {
        self.address = address
        self.capacity = capacity
        super.init()
    }

    @JavaMethod("capacity")
    public func javaCapacity() -> Int32 {
        Int32(truncatingIfNeeded: capacity)
    }
}

/// What ToReflectedMethod and ToReflectedField hand out.
@JavaClass("java/lang/reflect/AccessibleObject")
public final class JavaReflectedMember: JavaObject {
    let method: JavaMethod?
    let field: JavaField?

    init(method: JavaMethod?, field: JavaField?) {
        self.method = method
        self.field = field
        super.init()
    }
}

/// Stubs the trace writes return this: the zero of whatever they are.
public func javaStub<Value: JavaValueConvertible>() -> Value {
    Value.javaZero
}
