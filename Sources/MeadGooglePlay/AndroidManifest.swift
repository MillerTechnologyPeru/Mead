import Foundation

/// The package and version out of a compiled AndroidManifest.xml.
public struct AndroidManifest {
    public let packageName: String
    public let versionCode: Int

    public init?(path: String) {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        self.init(binary: [UInt8](data))
    }

    public init?(binary data: [UInt8]) {
        func u16(_ at: Int) -> Int { at + 2 <= data.count ? Int(data[at]) | Int(data[at + 1]) << 8 : 0 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard u16(0) == 3 else { return nil }
        var strings: [String] = []
        var position = 8
        while position + 8 <= data.count {
            let type = u16(position), size = u32(position + 4)
            guard size >= 8 else { return nil }
            if type == 1 {
                strings = Self.strings(data, pool: position, u16: u16, u32: u32)
            } else if type == 0x102 {
                let name = u32(position + 20)
                guard name < strings.count, strings[name] == "manifest" else {
                    position += size
                    continue
                }
                let start = position + 16 + u16(position + 24)
                let stride = u16(position + 26)
                var package: String?
                var version: Int?
                for index in 0..<u16(position + 28) {
                    let attribute = start + index * stride
                    let attributeName = u32(attribute + 4)
                    guard attributeName < strings.count else { continue }
                    if strings[attributeName] == "package", u32(attribute + 8) < strings.count {
                        package = strings[u32(attribute + 8)]
                    } else if strings[attributeName] == "versionCode" {
                        version = u32(attribute + 16)
                    }
                }
                guard let package, let version else { return nil }
                packageName = package
                versionCode = version
                return
            }
            position += size
        }
        return nil
    }

    private static func strings(_ data: [UInt8], pool: Int, u16: (Int) -> Int, u32: (Int) -> Int) -> [String] {
        let count = u32(pool + 8), isUTF8 = u32(pool + 16) & 0x100 != 0, start = pool + u32(pool + 20)
        return (0..<count).map { index in
            var at = start + u32(pool + 28 + index * 4)
            if isUTF8 {
                at += data[at] & 0x80 != 0 ? 2 : 1 // length in characters
                var length = Int(data[at])
                at += 1
                if length & 0x80 != 0 {
                    length = (length & 0x7f) << 8 | Int(data[at])
                    at += 1
                }
                return String(decoding: data[at..<(at + length)], as: UTF8.self)
            }
            var length = u16(at)
            at += 2
            if length & 0x8000 != 0 {
                length = (length & 0x7fff) << 16 | u16(at)
                at += 2
            }
            return String(decoding: (0..<length).map { UInt16(u16(at + $0 * 2)) }, as: UTF16.self)
        }
    }
}
