/// A Swift type with a JNI meaning: its descriptor and how a jvalue holds it.
/// `@JavaClass` builds signatures and unpacks arguments with these.
public protocol JavaValueConvertible {
    static var javaDescriptor: String { get }
    static var javaZero: Self { get }
    static func fromJava(_ value: jvalue, in thread: JavaThread) -> Self
    func toJava(in thread: JavaThread) -> jvalue
}

extension Bool: JavaValueConvertible {
    public static var javaDescriptor: String { "Z" }
    public static var javaZero: Bool { false }
    public static func fromJava(_ value: jvalue, in thread: JavaThread) -> Bool { value.z != 0 }
    public func toJava(in thread: JavaThread) -> jvalue {
        var value = jvalue()
        value.z = self ? 1 : 0
        return value
    }
}

extension Int8: JavaValueConvertible {
    public static var javaDescriptor: String { "B" }
    public static var javaZero: Int8 { 0 }
    public static func fromJava(_ value: jvalue, in thread: JavaThread) -> Int8 { value.b }
    public func toJava(in thread: JavaThread) -> jvalue {
        var value = jvalue()
        value.b = self
        return value
    }
}

extension UInt16: JavaValueConvertible {
    public static var javaDescriptor: String { "C" }
    public static var javaZero: UInt16 { 0 }
    public static func fromJava(_ value: jvalue, in thread: JavaThread) -> UInt16 { value.c }
    public func toJava(in thread: JavaThread) -> jvalue {
        var value = jvalue()
        value.c = self
        return value
    }
}

extension Int16: JavaValueConvertible {
    public static var javaDescriptor: String { "S" }
    public static var javaZero: Int16 { 0 }
    public static func fromJava(_ value: jvalue, in thread: JavaThread) -> Int16 { value.s }
    public func toJava(in thread: JavaThread) -> jvalue {
        var value = jvalue()
        value.s = self
        return value
    }
}

extension Int32: JavaValueConvertible {
    public static var javaDescriptor: String { "I" }
    public static var javaZero: Int32 { 0 }
    public static func fromJava(_ value: jvalue, in thread: JavaThread) -> Int32 { value.i }
    public func toJava(in thread: JavaThread) -> jvalue {
        var value = jvalue()
        value.i = self
        return value
    }
}

extension Int64: JavaValueConvertible {
    public static var javaDescriptor: String { "J" }
    public static var javaZero: Int64 { 0 }
    public static func fromJava(_ value: jvalue, in thread: JavaThread) -> Int64 { value.j }
    public func toJava(in thread: JavaThread) -> jvalue {
        var value = jvalue()
        value.j = self
        return value
    }
}

extension Float: JavaValueConvertible {
    public static var javaDescriptor: String { "F" }
    public static var javaZero: Float { 0 }
    public static func fromJava(_ value: jvalue, in thread: JavaThread) -> Float { value.f }
    public func toJava(in thread: JavaThread) -> jvalue {
        var value = jvalue()
        value.f = self
        return value
    }
}

extension Double: JavaValueConvertible {
    public static var javaDescriptor: String { "D" }
    public static var javaZero: Double { 0 }
    public static func fromJava(_ value: jvalue, in thread: JavaThread) -> Double { value.d }
    public func toJava(in thread: JavaThread) -> jvalue {
        var value = jvalue()
        value.d = self
        return value
    }
}

/// A reference type. Java references can be null, so they cross as optionals.
public protocol JavaReferenceConvertible {
    static var javaDescriptor: String { get }
    static func fromReference(_ object: JavaObject?) -> Self?
    var asReference: JavaObject? { get }
}

extension JavaObject: JavaReferenceConvertible {
    public class var javaDescriptor: String { "L\(javaClassName);" }

    public class func fromReference(_ object: JavaObject?) -> Self? {
        object.map { $0 as! Self }
    }

    public var asReference: JavaObject? { self }
}

extension String: JavaReferenceConvertible {
    public static var javaDescriptor: String { "Ljava/lang/String;" }

    public static func fromReference(_ object: JavaObject?) -> String? {
        (object as? JavaString)?.swiftValue
    }

    public var asReference: JavaObject? { JavaString(self) }
}

extension Optional: JavaValueConvertible where Wrapped: JavaReferenceConvertible {
    public static var javaDescriptor: String { Wrapped.javaDescriptor }
    public static var javaZero: Wrapped? { nil }

    public static func fromJava(_ value: jvalue, in thread: JavaThread) -> Wrapped? {
        Wrapped.fromReference(thread.resolve(value.l))
    }

    public func toJava(in thread: JavaThread) -> jvalue {
        var value = jvalue()
        value.l = self.flatMap { thread.newLocal($0.asReference) }
        return value
    }
}
