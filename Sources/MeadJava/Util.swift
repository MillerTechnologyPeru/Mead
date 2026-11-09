import Glibc
import MeadJNI

private func checkIndex(_ index: Int32, count: Int) throws {
    guard index >= 0, Int(index) < count else {
        throw JavaException("java/lang/IndexOutOfBoundsException", "index \(index), size \(count)")
    }
}

@JavaClass("java/util/ArrayList", implements: ["java/util/List"])
public final class JavaArrayList: JavaObject {
    public var elements: [JavaObject?] = []

    @JavaMethod public override init() {
        super.init()
    }

    @JavaMethod public init(capacity: Int32) {
        elements.reserveCapacity(max(Int(capacity), 0))
        super.init()
    }

    @JavaMethod("size") public func size() -> Int32 { Int32(elements.count) }
    @JavaMethod("isEmpty") public func isEmpty() -> Bool { elements.isEmpty }
    @JavaMethod("clear") public func clear() { elements.removeAll() }

    @JavaMethod("add") public func add(_ element: JavaObject?) -> Bool {
        elements.append(element)
        return true
    }

    @JavaMethod("get") public func get(_ index: Int32) throws -> JavaObject? {
        try checkIndex(index, count: elements.count)
        return elements[Int(index)]
    }

    @JavaMethod("set") public func set(_ index: Int32, _ element: JavaObject?) throws -> JavaObject? {
        try checkIndex(index, count: elements.count)
        let previous = elements[Int(index)]
        elements[Int(index)] = element
        return previous
    }

    @JavaMethod("remove") public func remove(_ index: Int32) throws -> JavaObject? {
        try checkIndex(index, count: elements.count)
        return elements.remove(at: Int(index))
    }
}

/// A map key by Java's idea of equal, for what has one here: strings by
/// their characters, boxes by value, and everything else by identity.
private struct MapKey: Hashable {
    let object: JavaObject?

    private enum Identity: Hashable {
        case null
        case units([UInt16])
        case integer(Int64)
        case object(ObjectIdentifier)
    }

    private var identity: Identity {
        switch object {
        case nil: return .null
        case let text as JavaString: return .units(text.units)
        case let number as JavaInteger: return .integer(Int64(number.value))
        case let number as JavaLong: return .integer(number.value)
        case let other?: return .object(ObjectIdentifier(other))
        }
    }

    static func == (left: MapKey, right: MapKey) -> Bool { left.identity == right.identity }
    func hash(into hasher: inout Hasher) { hasher.combine(identity) }
}

@JavaClass("java/util/HashMap", implements: ["java/util/Map"])
public final class JavaHashMap: JavaObject {
    private var entries: [MapKey: JavaObject?] = [:]

    @JavaMethod public override init() {
        super.init()
    }

    @JavaMethod("size") public func size() -> Int32 { Int32(entries.count) }
    @JavaMethod("isEmpty") public func isEmpty() -> Bool { entries.isEmpty }
    @JavaMethod("clear") public func clear() { entries.removeAll() }

    @JavaMethod("get") public func get(_ key: JavaObject?) -> JavaObject? {
        entries[MapKey(object: key)] ?? nil
    }

    @JavaMethod("containsKey") public func containsKey(_ key: JavaObject?) -> Bool {
        entries[MapKey(object: key)] != nil
    }

    @JavaMethod("put") public func put(_ key: JavaObject?, _ value: JavaObject?) -> JavaObject? {
        entries.updateValue(value, forKey: MapKey(object: key)) ?? nil
    }

    @JavaMethod("remove") public func remove(_ key: JavaObject?) -> JavaObject? {
        entries.removeValue(forKey: MapKey(object: key)) ?? nil
    }
}

@JavaClass("java/util/UUID")
public final class JavaUUID: JavaObject {
    private let text: String

    init(text: String) {
        self.text = text
        super.init()
    }

    @JavaMethod("randomUUID") public static func randomUUID() -> JavaUUID? {
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, bytes.count)
        bytes[6] = (bytes[6] & 0x0f) | 0x40 // version 4
        bytes[8] = (bytes[8] & 0x3f) | 0x80 // the RFC 4122 variant
        var text = ""
        for (index, byte) in bytes.enumerated() {
            if [4, 6, 8, 10].contains(index) {
                text += "-"
            }
            let digits = String(byte, radix: 16)
            text += digits.count == 1 ? "0\(digits)" : digits
        }
        return JavaUUID(text: text)
    }

    @JavaMethod("fromString") public static func fromString(_ text: String?) -> JavaUUID? {
        text.map { JavaUUID(text: $0) }
    }

    @JavaMethod("toString") public func javaToString() -> String? { text }
}

@JavaClass("java/util/Locale")
public final class JavaLocale: JavaObject {
    @JavaMethod("getDefault") public static func getDefault() -> JavaLocale? { JavaLocale() }
    @JavaMethod("getLanguage") public func getLanguage() -> String? { "en" }
    @JavaMethod("getCountry") public func getCountry() -> String? { "US" }
    @JavaMethod("toString") public func javaToString() -> String? { "en_US" }
}

@JavaClass("java/io/File")
public final class JavaFile: JavaObject {
    public let path: String

    @JavaMethod public init(path: String?) {
        self.path = path ?? ""
        super.init()
    }

    @JavaMethod("getPath") public func getPath() -> String? { path }
    @JavaMethod("getAbsolutePath") public func getAbsolutePath() -> String? { path }
    @JavaMethod("toString") public func javaToString() -> String? { path }
    @JavaMethod("exists") public func exists() -> Bool { access(path, F_OK) == 0 }
    @JavaMethod("mkdirs") public func mkdirs() -> Bool { AndroidEnvironment.makeDirectories(path) }

    @JavaMethod("isDirectory") public func isDirectory() -> Bool {
        var status = stat()
        return stat(path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFDIR
    }

    @JavaMethod("delete") public func delete() -> Bool { remove(path) == 0 }
}
