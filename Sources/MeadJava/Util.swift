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

    @JavaMethod("entrySet", signature: "()Ljava/util/Set;") public func entrySet() -> JavaCollection? {
        JavaCollection(entries.map { JavaMapEntry(key: $0.key.object, value: $0.value) })
    }

    @JavaMethod("keySet", signature: "()Ljava/util/Set;") public func keySet() -> JavaCollection? {
        JavaCollection(entries.keys.map(\.object))
    }

    @JavaMethod("values", signature: "()Ljava/util/Collection;") public func values() -> JavaCollection? {
        JavaCollection(Array(entries.values))
    }
}

/// What a map's entrySet, keySet and values are: a fixed set of elements
/// to iterate.
@JavaClass("java/util/HashSet", implements: ["java/util/Set"])
public final class JavaCollection: JavaObject {
    public let elements: [JavaObject?]

    public init(_ elements: [JavaObject?]) {
        self.elements = elements
        super.init()
    }

    @JavaMethod("size") public func size() -> Int32 { Int32(elements.count) }
    @JavaMethod("isEmpty") public func isEmpty() -> Bool { elements.isEmpty }
    @JavaMethod("iterator", signature: "()Ljava/util/Iterator;") public func iterator() -> JavaIterator? { JavaIterator(elements) }
}

@JavaClass("java/util/ArrayList$Itr", implements: ["java/util/Iterator"])
public final class JavaIterator: JavaObject {
    private let elements: [JavaObject?]
    private var position = 0

    public init(_ elements: [JavaObject?]) {
        self.elements = elements
        super.init()
    }

    @JavaMethod("hasNext") public func hasNext() -> Bool { position < elements.count }

    @JavaMethod("next", signature: "()Ljava/lang/Object;") public func next() throws -> JavaObject? {
        guard position < elements.count else { throw JavaException("java/util/NoSuchElementException", "") }
        defer { position += 1 }
        return elements[position]
    }
}

@JavaClass("java/util/AbstractMap$SimpleEntry", implements: ["java/util/Map$Entry"])
public final class JavaMapEntry: JavaObject {
    public let key: JavaObject?
    public let value: JavaObject?

    public init(key: JavaObject?, value: JavaObject?) {
        self.key = key
        self.value = value
        super.init()
    }

    @JavaMethod("getKey", signature: "()Ljava/lang/Object;") public func getKey() -> JavaObject? { key }
    @JavaMethod("getValue", signature: "()Ljava/lang/Object;") public func getValue() -> JavaObject? { value }
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
    @JavaMethod("toLanguageTag") public func toLanguageTag() -> String? { "en-US" }
    @JavaMethod("getVariant") public func getVariant() -> String? { "" }
    @JavaMethod("getScript") public func getScript() -> String? { "" }
    @JavaMethod("getISO3Language") public func getISO3Language() -> String? { "eng" }
    @JavaMethod("getISO3Country") public func getISO3Country() -> String? { "USA" }
    @JavaMethod("getDisplayLanguage", signature: "()Ljava/lang/String;") public func getDisplayLanguage() -> String? { "English" }
    @JavaMethod("getDisplayCountry", signature: "()Ljava/lang/String;") public func getDisplayCountry() -> String? { "United States" }
    @JavaMethod("getDisplayName", signature: "()Ljava/lang/String;") public func getDisplayName() -> String? { "English (United States)" }
}

@JavaClass("java/io/File")
public final class JavaFile: JavaObject {
    public let path: String

    @JavaMethod public init(path: String?) {
        self.path = path ?? ""
        super.init()
    }

    @JavaMethod(signature: "(Ljava/io/File;Ljava/lang/String;)V") public convenience init(parent: JavaObject?, child: String?) {
        self.init(path: Self.joined((parent as? JavaFile)?.path, child))
    }

    @JavaMethod(signature: "(Ljava/lang/String;Ljava/lang/String;)V") public convenience init(parentPath: String?, child: String?) {
        self.init(path: Self.joined(parentPath, child))
    }

    private static func joined(_ parent: String?, _ child: String?) -> String {
        guard let parent, !parent.isEmpty else { return child ?? "" }
        return parent.hasSuffix("/") ? parent + (child ?? "") : "\(parent)/\(child ?? "")"
    }

    /// Drops or adds the write bits, as Java's setReadOnly and setWritable do.
    private func setWriteBits(_ writable: Bool) -> Bool {
        var status = stat()
        guard stat(path, &status) == 0 else { return false }
        let bits = mode_t(S_IWUSR | S_IWGRP | S_IWOTH)
        return chmod(path, writable ? status.st_mode | mode_t(S_IWUSR) : status.st_mode & ~bits) == 0
    }

    @JavaMethod("setReadOnly") public func setReadOnly() -> Bool { setWriteBits(false) }
    @JavaMethod("setWritable", signature: "(Z)Z") public func setWritable(_ writable: Bool) -> Bool { setWriteBits(writable) }

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

    /// The path without its last part, as Java has it: nil when there is
    /// no slash, "/" for something in the root. Java's File drops a
    /// trailing slash when it's made, so one is dropped first here too.
    @JavaMethod("getParent") public func getParent() -> String? {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard let slash = trimmed.lastIndex(of: "/") else { return nil }
        if slash == trimmed.startIndex { return trimmed.count > 1 ? "/" : nil }
        return String(trimmed[..<slash])
    }

    @JavaMethod("getParentFile") public func getParentFile() -> JavaFile? { getParent().map { JavaFile(path: $0) } }

    @JavaMethod("getName") public func getName() -> String? {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return trimmed.lastIndex(of: "/").map { String(trimmed[trimmed.index(after: $0)...]) } ?? String(trimmed)
    }

    @JavaMethod("getCanonicalPath") public func getCanonicalPath() -> String? {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func space(_ measure: (statvfs) -> UInt64) -> Int64 {
        var status = statvfs()
        guard statvfs(path, &status) == 0 else { return 0 }
        return Int64(clamping: measure(status) * UInt64(status.f_frsize))
    }

    @JavaMethod("getTotalSpace") public func getTotalSpace() -> Int64 { space { UInt64($0.f_blocks) } }
    @JavaMethod("getFreeSpace") public func getFreeSpace() -> Int64 { space { UInt64($0.f_bfree) } }
    @JavaMethod("getUsableSpace") public func getUsableSpace() -> Int64 { space { UInt64($0.f_bavail) } }
}
