import Glibc
import MeadJNI

// Java's text and stream classes, as far as games use them through JNI:
// building strings, and reading a whole asset or file as text.

@JavaClass("java/lang/StringBuilder", implements: ["java/lang/CharSequence"])
public final class JavaStringBuilder: JavaObject {
    public private(set) var units: [UInt16] = []

    @JavaMethod public override init() {
        super.init()
    }

    @JavaMethod(signature: "(Ljava/lang/String;)V") public init(text: String?) {
        units = Array((text ?? "null").utf16)
        super.init()
    }

    @JavaMethod(signature: "(I)V") public init(capacity: Int32) {
        units.reserveCapacity(max(Int(capacity), 0))
        super.init()
    }

    private func appending(_ text: String) -> JavaStringBuilder {
        units += text.utf16
        return self
    }

    @JavaMethod("append", signature: "(Ljava/lang/String;)Ljava/lang/StringBuilder;")
    public func append(string: String?) -> JavaStringBuilder? { appending(string ?? "null") }

    @JavaMethod("append", signature: "(Ljava/lang/Object;)Ljava/lang/StringBuilder;")
    public func append(object: JavaObject?) -> JavaStringBuilder? {
        switch object {
        case nil: return appending("null")
        case let string as JavaString: return appending(string.swiftValue)
        case let builder as JavaStringBuilder: units += builder.units; return self
        case let object?: return appending("\(object.javaClass?.name.split(separator: "/").joined(separator: ".") ?? "Object")@\(String(UInt(bitPattern: ObjectIdentifier(object).hashValue) & 0xffff_ffff, radix: 16))")
        }
    }

    @JavaMethod("append", signature: "(I)Ljava/lang/StringBuilder;")
    public func append(int value: Int32) -> JavaStringBuilder? { appending(String(value)) }

    @JavaMethod("append", signature: "(J)Ljava/lang/StringBuilder;")
    public func append(long value: Int64) -> JavaStringBuilder? { appending(String(value)) }

    @JavaMethod("append", signature: "(Z)Ljava/lang/StringBuilder;")
    public func append(boolean value: Bool) -> JavaStringBuilder? { appending(value ? "true" : "false") }

    @JavaMethod("append", signature: "(C)Ljava/lang/StringBuilder;")
    public func append(char value: UInt16) -> JavaStringBuilder? {
        units.append(value)
        return self
    }

    @JavaMethod("append", signature: "(F)Ljava/lang/StringBuilder;")
    public func append(float value: Float) -> JavaStringBuilder? { appending(String(value)) }

    @JavaMethod("append", signature: "(D)Ljava/lang/StringBuilder;")
    public func append(double value: Double) -> JavaStringBuilder? { appending(String(value)) }

    @JavaMethod("length") public func length() -> Int32 { Int32(units.count) }
    @JavaMethod("toString") public func javaToString() -> String? { String(decoding: units, as: UTF16.self) }
}

/// A stream of bytes held whole: what an asset or a small file reads as.
@JavaClass("java/io/InputStream")
open class JavaInputStream: JavaObject {
    public let bytes: [UInt8]
    public private(set) var position = 0

    public init(bytes: [UInt8]) {
        self.bytes = bytes
        super.init()
    }

    /// What's left, and the stream is then at its end.
    public func readRemaining() -> [UInt8] {
        defer { position = bytes.count }
        return Array(bytes[position...])
    }

    @JavaMethod("read", signature: "()I") public func read() -> Int32 {
        guard position < bytes.count else { return -1 }
        defer { position += 1 }
        return Int32(bytes[position])
    }

    @JavaMethod("read", signature: "([BII)I") public func read(_ array: JavaObject?, _ offset: Int32, _ length: Int32) throws -> Int32 {
        guard let array = array as? JavaPrimitiveArray else {
            throw JavaException("java/lang/NullPointerException", "read(null)")
        }
        guard offset >= 0, length >= 0, Int(offset) + Int(length) <= array.count else {
            throw JavaException("java/lang/IndexOutOfBoundsException", "offset \(offset), length \(length), size \(array.count)")
        }
        guard length > 0 else { return 0 }
        guard position < bytes.count else { return -1 }
        let count = min(Int(length), bytes.count - position)
        bytes.withUnsafeBytes { source in
            (array.storage + Int(offset)).copyMemory(from: source.baseAddress! + position, byteCount: count)
        }
        position += count
        return Int32(count)
    }

    @JavaMethod("read", signature: "([B)I") public func read(_ array: JavaObject?) throws -> Int32 {
        try read(array, 0, Int32((array as? JavaPrimitiveArray)?.count ?? 0))
    }

    @JavaMethod("available") public func available() -> Int32 { Int32(bytes.count - position) }
    @JavaMethod("close") public func close() {}
}

/// AssetManager.open's stream.
@JavaClass("android/content/res/AssetManager$AssetInputStream")
public final class JavaAssetInputStream: JavaInputStream {}

/// java.util.Scanner, for what games read with one: a stream's whole text
/// (delimiter "\\A", the usual way to read a file in one go) or its
/// whitespace-separated words.
@JavaClass("java/util/Scanner")
public final class JavaScanner: JavaObject {
    private var text: [Character]
    private var position = 0
    private var wholeText = false

    @JavaMethod(signature: "(Ljava/io/InputStream;Ljava/lang/String;)V")
    public init(stream: JavaObject?, charset: String?) {
        text = Array(String(decoding: (stream as? JavaInputStream)?.readRemaining() ?? [], as: UTF8.self))
        super.init()
    }

    @JavaMethod(signature: "(Ljava/io/InputStream;)V")
    public init(stream: JavaObject?) {
        text = Array(String(decoding: (stream as? JavaInputStream)?.readRemaining() ?? [], as: UTF8.self))
        super.init()
    }

    @JavaMethod(signature: "(Ljava/lang/String;)V")
    public init(source: String?) {
        text = Array(source ?? "")
        super.init()
    }

    @JavaMethod("useDelimiter", signature: "(Ljava/lang/String;)Ljava/util/Scanner;")
    public func useDelimiter(_ pattern: String?) -> JavaScanner? {
        wholeText = pattern == "\\A" || pattern == "\\Z"
        return self
    }

    private func skipSpace() {
        while position < text.count, text[position].isWhitespace { position += 1 }
    }

    @JavaMethod("hasNext") public func hasNext() -> Bool {
        if wholeText { return position < text.count }
        skipSpace()
        return position < text.count
    }

    @JavaMethod("next") public func next() throws -> String? {
        guard hasNext() else {
            throw JavaException("java/util/NoSuchElementException", "")
        }
        let start = position
        if wholeText {
            position = text.count
        } else {
            while position < text.count, !text[position].isWhitespace { position += 1 }
        }
        return String(text[start..<position])
    }

    @JavaMethod("close") public func close() {}
}

/// The intent an activity was started with: the launcher's, with nothing in it.
@JavaClass("android/content/Intent")
public final class JavaIntent: JavaObject {
    @JavaMethod("getAction") public func getAction() -> String? { "android.intent.action.MAIN" }
    @JavaMethod("getStringExtra") public func getStringExtra(_ name: String?) -> String? { nil }
    @JavaMethod("getExtras", signature: "()Landroid/os/Bundle;") public func getExtras() -> JavaObject? { nil }
    @JavaMethod("getData", signature: "()Landroid/net/Uri;") public func getData() -> JavaObject? { nil }
}

/// android.os.Process: the IDs, and priorities, which a game may ask for and
/// do without.
@JavaClass("android/os/Process")
public final class JavaProcess: JavaObject {
    @JavaMethod("myPid") public static func myPid() -> Int32 { getpid() }
    @JavaMethod("myTid") public static func myTid() -> Int32 { gettid() }
    @JavaMethod("myUid") public static func myUid() -> Int32 { Int32(bitPattern: getuid()) }
    @JavaMethod("setThreadPriority", signature: "(II)V") public static func setThreadPriority(_ thread: Int32, _ priority: Int32) {}
    @JavaMethod("setThreadPriority", signature: "(I)V") public static func setThreadPriority(_ priority: Int32) {}
    @JavaMethod("getThreadPriority") public static func getThreadPriority(_ thread: Int32) -> Int32 { 0 }
}

/// glibc's gettid, which Swift's Glibc module doesn't show.
private let gettid: @convention(c) () -> Int32 = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: 0), "gettid") else { return { getpid() } }
    return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
}()
