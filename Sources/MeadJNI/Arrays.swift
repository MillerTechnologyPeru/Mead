import Glibc

/// A Java primitive array, whose storage never moves, so that JNI's element
/// and critical accessors can hand out the array itself.
public final class JavaPrimitiveArray: JavaObject {
    public let kind: UInt8
    public let count: Int
    public let storage: UnsafeMutableRawPointer

    public static func elementSize(_ kind: UInt8) -> Int {
        switch kind {
        case UInt8(ascii: "Z"), UInt8(ascii: "B"): return 1
        case UInt8(ascii: "C"), UInt8(ascii: "S"): return 2
        case UInt8(ascii: "I"), UInt8(ascii: "F"): return 4
        default: return 8
        }
    }

    public var elementSize: Int { Self.elementSize(kind) }

    init(kind: UInt8, count: Int, type: JavaClass) {
        self.kind = kind
        self.count = count
        storage = calloc(max(count, 1), Self.elementSize(kind))!
        super.init(javaClass: type)
    }

    deinit {
        free(storage)
    }
}

/// A Java array of references.
public final class JavaObjectArray: JavaObject {
    public var elements: [JavaObject?]

    init(count: Int, initial: JavaObject?, type: JavaClass) {
        elements = Array(repeating: initial, count: count)
        super.init(javaClass: type)
    }
}
