// The little cryptography Mead needs, all of it checking signatures: RSA with
// PKCS#1 v1.5 padding, SHA-1 and SHA-256, and the X.509 wrapping of a key.

/// An RSA public key, as big-endian bytes without leading zeros.
public struct RSAPublicKey: Sendable {
    public let modulus: [UInt8]
    public let exponent: [UInt8]

    private static let sha256DigestInfo: [UInt8] = [
        0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
    ]
    private static let sha1DigestInfo: [UInt8] = [
        0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14,
    ]

    public init(modulus: [UInt8], exponent: [UInt8]) {
        self.modulus = modulus
        self.exponent = exponent
    }

    /// Reads an X.509 SubjectPublicKeyInfo holding an RSA key.
    public init?(subjectPublicKeyInfo der: [UInt8]) {
        var outer = DERReader(der)
        guard var info = outer.read(tag: 0x30).map(DERReader.init),
              var algorithm = info.read(tag: 0x30).map(DERReader.init),
              algorithm.read(tag: 0x06) == [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01],
              let bits = info.read(tag: 0x03), bits.first == 0 else { return nil }
        var inner = DERReader(Array(bits.dropFirst()))
        guard var key = inner.read(tag: 0x30).map(DERReader.init),
              let modulus = key.read(tag: 0x02), let exponent = key.read(tag: 0x02) else { return nil }
        func trimmed(_ value: [UInt8]) -> [UInt8] { Array(value.drop { $0 == 0 }) }
        self.init(modulus: trimmed(modulus), exponent: trimmed(exponent))
    }

    /// RSASSA-PKCS1-v1_5 with SHA-256.
    public func verifySHA256(message: [UInt8], signature: [UInt8]) -> Bool {
        verify(digestInfo: Self.sha256DigestInfo + SHA256.hash(message), signature: signature)
    }

    /// RSASSA-PKCS1-v1_5 with SHA-1, which Google Play's license responses use.
    public func verifySHA1(message: [UInt8], signature: [UInt8]) -> Bool {
        verify(digestInfo: Self.sha1DigestInfo + SHA1.hash(message), signature: signature)
    }

    private func verify(digestInfo: [UInt8], signature: [UInt8]) -> Bool {
        guard !modulus.isEmpty, signature.count == modulus.count else { return false }
        let padded = BigNumber.power(signature, exponent, modulus: modulus)
        guard padded.count >= digestInfo.count + 11 else { return false }
        let filler = [UInt8](repeating: 0xff, count: padded.count - digestInfo.count - 3)
        return padded == [0x00, 0x01] + filler + [0x00] + digestInfo
    }
}

/// Just enough DER: tag, definite length, contents.
private struct DERReader {
    private let data: [UInt8]
    private var position = 0

    init(_ data: [UInt8]) { self.data = data }

    mutating func read(tag: UInt8) -> [UInt8]? {
        guard position + 2 <= data.count, data[position] == tag else { return nil }
        var length = Int(data[position + 1])
        position += 2
        if length & 0x80 != 0 {
            let octets = length & 0x7f
            guard octets > 0, octets <= 4, position + octets <= data.count else { return nil }
            length = data[position..<(position + octets)].reduce(0) { $0 << 8 | Int($1) }
            position += octets
        }
        guard position + length <= data.count else { return nil }
        defer { position += length }
        return Array(data[position..<(position + length)])
    }
}

/// Unsigned arithmetic for one purpose: `base ^ exponent mod modulus`. Public
/// values only, so nothing here needs to run in constant time.
private enum BigNumber {
    /// Big-endian bytes to little-endian limbs, `count` of them.
    private static func limbs(_ bytes: [UInt8], count: Int) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: count)
        for (index, byte) in bytes.reversed().enumerated() where index / 4 < count {
            result[index / 4] |= UInt32(byte) << UInt32(index % 4 * 8)
        }
        return result
    }

    private static func isAtLeast(_ left: [UInt32], _ right: [UInt32]) -> Bool {
        for index in stride(from: left.count - 1, through: 0, by: -1) where left[index] != right[index] {
            return left[index] > right[index]
        }
        return true
    }

    private static func subtract(_ value: inout [UInt32], _ other: [UInt32]) {
        var borrow: UInt64 = 0
        for index in value.indices {
            let difference = UInt64(value[index]) &- UInt64(other[index]) &- borrow
            value[index] = UInt32(truncatingIfNeeded: difference)
            borrow = difference >> 63
        }
    }

    private static func add(_ value: inout [UInt32], _ other: [UInt32]) {
        var carry: UInt64 = 0
        for index in value.indices {
            let sum = UInt64(value[index]) + UInt64(other[index]) + carry
            value[index] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }
    }

    private static func shiftLeft(_ value: inout [UInt32]) {
        var carry: UInt32 = 0
        for index in value.indices {
            let next = value[index] >> 31
            value[index] = value[index] << 1 | carry
            carry = next
        }
    }

    /// `left * right mod modulus`, by doubling. Everything has one spare limb.
    private static func multiply(_ left: [UInt32], _ right: [UInt32], modulus: [UInt32]) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: modulus.count)
        for bit in stride(from: (right.count - 1) * 32 - 1, through: 0, by: -1) {
            shiftLeft(&result)
            if isAtLeast(result, modulus) { subtract(&result, modulus) }
            if right[bit / 32] >> UInt32(bit % 32) & 1 == 1 {
                add(&result, left)
                if isAtLeast(result, modulus) { subtract(&result, modulus) }
            }
        }
        return result
    }

    /// The result, big-endian and as long as the modulus.
    static func power(_ base: [UInt8], _ exponent: [UInt8], modulus: [UInt8]) -> [UInt8] {
        let count = (modulus.count + 3) / 4 + 1
        let modulusLimbs = limbs(modulus, count: count)
        var reduced = limbs(base, count: count)
        while isAtLeast(reduced, modulusLimbs) { subtract(&reduced, modulusLimbs) }
        var result = [UInt32](repeating: 0, count: count)
        result[0] = 1
        for byte in exponent {
            for bit in stride(from: 7, through: 0, by: -1) {
                result = multiply(result, result, modulus: modulusLimbs)
                if byte >> UInt8(bit) & 1 == 1 {
                    result = multiply(result, reduced, modulus: modulusLimbs)
                }
            }
        }
        return (0..<modulus.count).reversed().map { UInt8(truncatingIfNeeded: result[$0 / 4] >> UInt32($0 % 4 * 8)) }
    }
}

public enum SHA256 {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public static func hash(_ message: [UInt8]) -> [UInt8] {
        func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { value >> count | value << (32 - count) }
        var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var data = message + [0x80]
        data += [UInt8](repeating: 0, count: (120 - data.count % 64) % 64)
        let bits = UInt64(message.count) * 8
        data += (0..<8).reversed().map { UInt8(truncatingIfNeeded: bits >> UInt64($0 * 8)) }
        for block in stride(from: 0, to: data.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                words[index] = (0..<4).reduce(0) { $0 << 8 | UInt32(data[block + index * 4 + $1]) }
            }
            for index in 16..<64 {
                let first = words[index - 15], second = words[index - 2]
                let small0 = rotate(first, 7) ^ rotate(first, 18) ^ (first >> 3)
                let small1 = rotate(second, 17) ^ rotate(second, 19) ^ (second >> 10)
                words[index] = words[index - 16] &+ small0 &+ words[index - 7] &+ small1
            }
            var v = state
            for index in 0..<64 {
                let big1 = rotate(v[4], 6) ^ rotate(v[4], 11) ^ rotate(v[4], 25)
                let choose = (v[4] & v[5]) ^ (~v[4] & v[6])
                let first = v[7] &+ big1 &+ choose &+ constants[index] &+ words[index]
                let big0 = rotate(v[0], 2) ^ rotate(v[0], 13) ^ rotate(v[0], 22)
                let majority = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2])
                v = [first &+ big0 &+ majority, v[0], v[1], v[2], v[3] &+ first, v[4], v[5], v[6]]
            }
            for index in 0..<8 { state[index] = state[index] &+ v[index] }
        }
        return state.flatMap { word in (0..<4).reversed().map { UInt8(truncatingIfNeeded: word >> UInt32($0 * 8)) } }
    }
}

public enum SHA1 {
    public static func hash(_ message: [UInt8]) -> [UInt8] {
        func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { value << count | value >> (32 - count) }
        var state: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0]
        var data = message + [0x80]
        data += [UInt8](repeating: 0, count: (120 - data.count % 64) % 64)
        let bits = UInt64(message.count) * 8
        data += (0..<8).reversed().map { UInt8(truncatingIfNeeded: bits >> UInt64($0 * 8)) }
        for block in stride(from: 0, to: data.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 80)
            for index in 0..<16 {
                words[index] = (0..<4).reduce(0) { $0 << 8 | UInt32(data[block + index * 4 + $1]) }
            }
            for index in 16..<80 {
                words[index] = rotate(words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16], 1)
            }
            var (a, b, c, d, e) = (state[0], state[1], state[2], state[3], state[4])
            for index in 0..<80 {
                let (function, constant): (UInt32, UInt32)
                switch index {
                case 0..<20: (function, constant) = ((b & c) | (~b & d), 0x5a827999)
                case 20..<40: (function, constant) = (b ^ c ^ d, 0x6ed9eba1)
                case 40..<60: (function, constant) = ((b & c) | (b & d) | (c & d), 0x8f1bbcdc)
                default: (function, constant) = (b ^ c ^ d, 0xca62c1d6)
                }
                let next = rotate(a, 5) &+ function &+ e &+ constant &+ words[index]
                (a, b, c, d, e) = (next, a, rotate(b, 30), c, d)
            }
            state = [state[0] &+ a, state[1] &+ b, state[2] &+ c, state[3] &+ d, state[4] &+ e]
        }
        return state.flatMap { word in (0..<4).reversed().map { UInt8(truncatingIfNeeded: word >> UInt32($0 * 8)) } }
    }
}
