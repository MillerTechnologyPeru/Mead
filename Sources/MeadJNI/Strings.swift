import Glibc

/// A java/lang/String: UTF-16 code units, as Java sees them.
@JavaClass("java/lang/String")
public final class JavaString: JavaObject {
    public let units: [UInt16]

    public init(units: [UInt16]) {
        self.units = units
        super.init()
    }

    public convenience init(_ text: String) {
        self.init(units: Array(text.utf16))
    }

    @JavaMethod public convenience override init() {
        self.init(units: [])
    }

    /// new String(bytes): text in UTF-8, Android's default.
    @JavaMethod(signature: "([B)V") public convenience init(bytes: JavaObject?) {
        self.init(units: Self.decode(bytes, charset: nil))
    }

    /// new String(bytes, charset), how native code makes a string that isn't
    /// modified UTF-8.
    @JavaMethod(signature: "([BLjava/lang/String;)V") public convenience init(bytes: JavaObject?, charset: String?) {
        self.init(units: Self.decode(bytes, charset: charset))
    }

    private static func decode(_ array: JavaObject?, charset: String?) -> [UInt16] {
        guard let array = array as? JavaPrimitiveArray else { return [] }
        let bytes = UnsafeRawBufferPointer(start: array.storage, count: array.count)
        switch charset?.uppercased() {
        case "ISO-8859-1", "ISO8859_1", "LATIN1", "US-ASCII", "ASCII": return bytes.map(UInt16.init)
        default: return Array(String(decoding: bytes, as: UTF8.self).utf16)
        }
    }

    public var swiftValue: String {
        String(decoding: units, as: UTF16.self)
    }

    @JavaMethod("length")
    public func javaLength() -> Int32 {
        Int32(units.count)
    }

    @JavaMethod("toString")
    public func javaToString() -> JavaString? {
        self
    }

    /// Strings are equal by their text, not by being the same object:
    /// native code compares a returned string with a constant this way.
    @JavaMethod("equals", signature: "(Ljava/lang/Object;)Z")
    public func javaEquals(_ other: JavaObject?) -> Bool {
        (other as? JavaString)?.units == units
    }

    @JavaMethod("hashCode")
    public func javaHashCode() -> Int32 {
        units.reduce(Int32(0)) { $0 &* 31 &+ Int32($1) }
    }

    @JavaMethod("isEmpty")
    public func javaIsEmpty() -> Bool {
        units.isEmpty
    }
}

/// Modified UTF-8, JNI's encoding: NUL is two bytes so that no byte of a
/// string is ever 0, and a supplementary character is its two surrogates,
/// three bytes each.
public enum ModifiedUTF8 {
    public static func encode(_ units: [UInt16]) -> [UInt8] {
        encode(units[...])
    }

    public static func encode(_ units: ArraySlice<UInt16>) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(units.count)
        for unit in units {
            switch unit {
            case 0x0001...0x007f:
                bytes.append(UInt8(unit))
            case 0x0000, 0x0080...0x07ff:
                bytes.append(UInt8(0xc0 | (unit >> 6)))
                bytes.append(UInt8(0x80 | (unit & 0x3f)))
            default:
                bytes.append(UInt8(0xe0 | (unit >> 12)))
                bytes.append(UInt8(0x80 | ((unit >> 6) & 0x3f)))
                bytes.append(UInt8(0x80 | (unit & 0x3f)))
            }
        }
        return bytes
    }

    /// Decodes a NUL-terminated string, tolerating the four-byte sequences
    /// plain UTF-8 uses for a supplementary character, as ART does.
    public static func decode(_ string: UnsafePointer<CChar>) -> [UInt16] {
        let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(string).assumingMemoryBound(to: UInt8.self), count: strlen(string))
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count)
        var index = 0

        func continuation(_ offset: Int) -> UInt32 {
            index + offset < bytes.count ? UInt32(bytes[index + offset] & 0x3f) : 0
        }

        while index < bytes.count {
            let lead = bytes[index]
            switch lead {
            case 0x00...0x7f:
                units.append(UInt16(lead))
                index += 1
            case 0xc0...0xdf:
                units.append(UInt16((UInt32(lead & 0x1f) << 6) | continuation(1)))
                index += 2
            case 0xe0...0xef:
                units.append(UInt16(truncatingIfNeeded: (UInt32(lead & 0x0f) << 12) | (continuation(1) << 6) | continuation(2)))
                index += 3
            case 0xf0...0xf7:
                let scalar = (UInt32(lead & 0x07) << 18) | (continuation(1) << 12) | (continuation(2) << 6) | continuation(3)
                let offset = scalar &- 0x10000
                units.append(UInt16(truncatingIfNeeded: 0xd800 + (offset >> 10)))
                units.append(UInt16(truncatingIfNeeded: 0xdc00 + (offset & 0x3ff)))
                index += 4
            default:
                units.append(0xfffd)
                index += 1
            }
        }
        return units
    }
}
