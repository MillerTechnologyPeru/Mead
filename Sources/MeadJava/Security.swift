import Glibc
import MeadCrypto
import MeadJNI

// java.security, as far as verifying a signature goes, and the small things
// that come with it. All of it computes the real answer: a signature that
// doesn't verify says so, here as it would on a phone.

private func bytes(of object: JavaObject?) -> [UInt8]? {
    guard let array = object as? JavaPrimitiveArray, array.kind == UInt8(ascii: "B") else { return nil }
    return Array(UnsafeRawBufferPointer(start: array.storage, count: array.count))
}

@JavaClass("android/util/Base64")
public final class JavaBase64: JavaObject {
    @JavaField("DEFAULT") public static var defaultFlags: Int32 = 0
    @JavaField("NO_PADDING") public static var noPadding: Int32 = 1
    @JavaField("NO_WRAP") public static var noWrap: Int32 = 2
    @JavaField("CRLF") public static var crlf: Int32 = 4
    @JavaField("URL_SAFE") public static var urlSafe: Int32 = 8

    /// Android's decoder: anything outside the alphabet is skipped, and `=`
    /// is only allowed where padding belongs.
    static func decode(_ input: [UInt8], urlSafe: Bool) -> [UInt8]? {
        func value(_ character: UInt8) -> Int? {
            switch character {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): return Int(character) - 65
            case UInt8(ascii: "a")...UInt8(ascii: "z"): return Int(character) - 71
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(character) + 4
            case UInt8(ascii: "+") where !urlSafe, UInt8(ascii: "-") where urlSafe: return 62
            case UInt8(ascii: "/") where !urlSafe, UInt8(ascii: "_") where urlSafe: return 63
            default: return nil
            }
        }
        var output: [UInt8] = []
        var accumulator = 0
        var count = 0
        var missingPadding = -1 // -1 before any padding, then how many `=` are still due
        for character in input {
            if character == UInt8(ascii: "=") {
                switch (count, missingPadding) {
                case (2, -1): missingPadding = 1
                case (3, -1): missingPadding = 0
                case (2, 1): missingPadding = 0
                default: return nil
                }
                continue
            }
            guard let digit = value(character) else { continue }
            guard missingPadding < 0 else { return nil }
            accumulator = accumulator << 6 | digit
            count += 1
            if count == 4 {
                output += [UInt8(accumulator >> 16 & 0xff), UInt8(accumulator >> 8 & 0xff), UInt8(accumulator & 0xff)]
                accumulator = 0
                count = 0
            }
        }
        switch count {
        case 0: break
        case 2 where missingPadding <= 0: output.append(UInt8(accumulator >> 4 & 0xff))
        case 3 where missingPadding <= 0: output += [UInt8(accumulator >> 10 & 0xff), UInt8(accumulator >> 2 & 0xff)]
        default: return nil
        }
        return output
    }

    @JavaMethod("decode", signature: "(Ljava/lang/String;I)[B")
    public static func decode(_ text: String?, _ flags: Int32) throws -> JavaObject? {
        guard let decoded = decode(Array((text ?? "").utf8), urlSafe: flags & 8 != 0) else {
            throw JavaException("java/lang/IllegalArgumentException", "bad base-64")
        }
        return JavaRuntime.shared.newByteArray(decoded)
    }
}

@JavaClass("java/util/Arrays")
public final class JavaArrays: JavaObject {
    @JavaMethod("copyOfRange", signature: "([BII)[B")
    public static func copyOfRange(_ source: JavaObject?, _ from: Int32, _ to: Int32) throws -> JavaObject? {
        guard let source = bytes(of: source) else {
            throw JavaException("java/lang/NullPointerException", nil)
        }
        guard from <= to else {
            throw JavaException("java/lang/IllegalArgumentException", "\(from) > \(to)")
        }
        guard from >= 0, from <= source.count else {
            throw JavaException("java/lang/ArrayIndexOutOfBoundsException", "\(from)")
        }
        let end = min(Int(to), source.count)
        return JavaRuntime.shared.newByteArray(Array(source[Int(from)..<end]) + [UInt8](repeating: 0, count: Int(to) - end))
    }
}

@JavaClass("java/security/spec/X509EncodedKeySpec", implements: ["java/security/spec/KeySpec"])
public final class JavaX509EncodedKeySpec: JavaObject {
    let encoded: [UInt8]

    @JavaMethod(signature: "([B)V") public init(encoded: JavaObject?) {
        self.encoded = bytes(of: encoded) ?? []
        super.init()
    }
}

@JavaClass("java/security/interfaces/RSAPublicKey", implements: ["java/security/PublicKey"])
public final class JavaRSAPublicKey: JavaObject {
    let key: RSAPublicKey

    init(key: RSAPublicKey) {
        self.key = key
        super.init()
    }
}

@JavaClass("java/security/KeyFactory")
public final class JavaKeyFactory: JavaObject {
    @JavaMethod("getInstance", signature: "(Ljava/lang/String;)Ljava/security/KeyFactory;")
    public static func getInstance(_ algorithm: String?) throws -> JavaKeyFactory? {
        guard algorithm == "RSA" else {
            throw JavaException("java/security/NoSuchAlgorithmException", algorithm)
        }
        return JavaKeyFactory()
    }

    @JavaMethod("generatePublic", signature: "(Ljava/security/spec/KeySpec;)Ljava/security/PublicKey;")
    public func generatePublic(_ specification: JavaObject?) throws -> JavaObject? {
        guard let specification = specification as? JavaX509EncodedKeySpec,
              let key = RSAPublicKey(subjectPublicKeyInfo: specification.encoded) else {
            throw JavaException("java/security/spec/InvalidKeySpecException", nil)
        }
        return JavaRSAPublicKey(key: key)
    }
}

@JavaClass("java/security/Signature")
public final class JavaSignature: JavaObject {
    private var key: JavaRSAPublicKey?
    private var message: [UInt8] = []

    @JavaMethod("getInstance", signature: "(Ljava/lang/String;)Ljava/security/Signature;")
    public static func getInstance(_ algorithm: String?) throws -> JavaSignature? {
        guard algorithm == "SHA256withRSA" else {
            throw JavaException("java/security/NoSuchAlgorithmException", algorithm)
        }
        return JavaSignature()
    }

    @JavaMethod("initVerify", signature: "(Ljava/security/PublicKey;)V")
    public func initVerify(_ key: JavaObject?) throws {
        guard let key = key as? JavaRSAPublicKey else {
            throw JavaException("java/security/InvalidKeyException", nil)
        }
        self.key = key
        message = []
    }

    @JavaMethod("update", signature: "([B)V")
    public func update(_ data: JavaObject?) {
        message += bytes(of: data) ?? []
    }

    @JavaMethod("verify", signature: "([B)Z")
    public func verify(_ signature: JavaObject?) throws -> Bool {
        guard let key else { throw JavaException("java/security/SignatureException", "not initialized") }
        defer { message = [] }
        return key.key.verifySHA256(message: message, signature: bytes(of: signature) ?? [])
    }
}
