import Foundation
import MeadCrypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What came of asking Google whether this account has the game.
public struct LicenseResult {
    /// True only for a response signed with the game's own key, for this
    /// package, version and nonce, that says the account is licensed.
    public let verified: Bool
    public let validationTime: Int64
    public let retryUntilTime: Int64
    public let retryAttempts: Int64
    public let reason: String
    /// A signed answer from Google that the account is not licensed, rather
    /// than a failure to get an answer at all.
    let googleSaidNo: Bool

    init(verified: Bool, validationTime: Int64, retryUntilTime: Int64, retryAttempts: Int64, reason: String, googleSaidNo: Bool = false) {
        self.verified = verified
        self.validationTime = validationTime
        self.retryUntilTime = retryUntilTime
        self.retryAttempts = retryAttempts
        self.reason = reason
        self.googleSaidNo = googleSaidNo
    }

    static func unverified(_ reason: String, googleSaidNo: Bool = false) -> LicenseResult {
        LicenseResult(verified: false, validationTime: 0, retryUntilTime: 0, retryAttempts: 0, reason: reason, googleSaidNo: googleSaidNo)
    }
}

/// Google's last signed "licensed" answer, kept as Android's License
/// Verification Library keeps it (ServerManagedPolicy): it stands in when
/// Google can't be asked, until the validity time Google signed into it. It is
/// checked again, signature and all, every time it is used, so editing the
/// file can't extend it; and a signed "not licensed" from Google removes it.
public struct LicenseCache {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// Beside the account: ~/.mead/google/license-<package>.json.
    public static func standard(for packageName: String) -> LicenseCache {
        let directory = (GoogleAccount.defaultPath as NSString).deletingLastPathComponent
        return LicenseCache(path: "\(directory)/license-\(packageName).json")
    }

    struct Entry: Codable {
        let signedData: String
        let signature: String
        let result: Int
    }

    func load() -> LicenseAnswer? {
        guard let data = FileManager.default.contents(atPath: path),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        return LicenseAnswer(result: entry.result, signedData: entry.signedData, signature: entry.signature)
    }

    func save(_ answer: LicenseAnswer) {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(Entry(signedData: answer.signedData, signature: answer.signature, result: answer.result)) else { return }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        fchmod(descriptor, 0o600)
        _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Google Play's License Verification Library, as a client: one request to
/// Google, and the checks a game would make of the signed answer.
public struct GooglePlayLicense {
    private let auth: GoogleAuth
    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
        auth = GoogleAuth(transport: transport)
    }

    /// Never throws: a failure to find out is an unverified license, unless
    /// `cache` holds an answer from Google that is still valid.
    public func check(account: GoogleAccount?, packageName: String, versionCode: Int, publicKey: String,
                      cache: LicenseCache? = nil, nonce: Int32 = Int32.random(in: 1...Int32.max),
                      now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> LicenseResult {
        let asked = ask(account: account, packageName: packageName, versionCode: versionCode, publicKey: publicKey, nonce: nonce)
        guard let cache else { return asked.result }
        if asked.result.verified, let answer = asked.answer {
            cache.save(answer)
            return asked.result
        }
        if asked.result.googleSaidNo {
            cache.remove()
            return asked.result
        }
        // Google couldn't be asked: its last answer, while Google said it holds.
        guard let cached = cache.load() else { return asked.result }
        let kept = Self.evaluate(cached, packageName: packageName, versionCode: versionCode, nonce: nil, publicKey: publicKey)
        guard kept.verified, kept.validationTime > now else { return asked.result }
        return LicenseResult(verified: true, validationTime: kept.validationTime, retryUntilTime: kept.retryUntilTime,
                             retryAttempts: kept.retryAttempts,
                             reason: "Google's last answer, licensed until \(Date(timeIntervalSince1970: Double(kept.validationTime) / 1000)), stands in: \(asked.result.reason)")
    }

    private func ask(account: GoogleAccount?, packageName: String, versionCode: Int, publicKey: String,
                     nonce: Int32) -> (result: LicenseResult, answer: LicenseAnswer?) {
        guard let account else {
            return (.unverified("not signed in to Google; run mead-google-login"), nil)
        }
        do {
            let token = try auth.playToken(for: account)
            var request = URLRequest(url: URL(string: "https://play-fe.googleapis.com/fdfe/apps/checkLicense?pkgn=\(packageName)&vc=\(versionCode)&nnc=\(nonce)")!, timeoutInterval: 30)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(account.androidID, forHTTPHeaderField: "X-DFE-Device-Id")
            request.setValue("am-google", forHTTPHeaderField: "X-DFE-Client-Id")
            request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
            request.setValue("Android-Finsky/37.5.24-29 (api=3,sdk=35,device=mead,hardware=mead,product=mead,model=mead,buildId=mead,supportedAbis=arm64-v8a)", forHTTPHeaderField: "User-Agent")
            let response = try transport.send(request)
            guard response.status == 200 else {
                return (.unverified("Google's license server answered HTTP \(response.status)"), nil)
            }
            guard let answer = LicenseAnswer(protobuf: [UInt8](response.body)) else {
                return (.unverified("no license in Google's response"), nil)
            }
            return (Self.evaluate(answer, packageName: packageName, versionCode: versionCode, nonce: nonce, publicKey: publicKey), answer)
        } catch {
            return (.unverified("\(error)"), nil)
        }
    }

    /// The checks LVL makes: the signature first, then that the signed text
    /// says what this request asked about. A kept answer has no request of
    /// its own, so `nonce` is nil for one; the rest is checked all the same.
    static func evaluate(_ answer: LicenseAnswer, packageName: String, versionCode: Int, nonce: Int32?, publicKey: String) -> LicenseResult {
        guard let keyBytes = Data(base64Encoded: publicKey), let key = RSAPublicKey(subjectPublicKeyInfo: [UInt8](keyBytes)) else {
            return .unverified("the game's public key cannot be read")
        }
        guard let signature = Data(base64Encoded: answer.signature),
              key.verifySHA1(message: Array(answer.signedData.utf8), signature: [UInt8](signature)) else {
            return .unverified("the response's signature does not verify")
        }
        let parts = answer.signedData.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let fields = parts[0].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 6 else { return .unverified("the signed response is malformed") }
        guard Int(fields[0]) == answer.result, nonce.map({ fields[1] == String($0) }) ?? true, fields[2] == packageName,
              fields[3] == String(versionCode) else {
            return .unverified("the signed response is for a different request")
        }
        // 0 is licensed, and 2 licensed under an older key.
        guard answer.result == 0 || answer.result == 2 else {
            return .unverified("Google says this account is not licensed (code \(answer.result))", googleSaidNo: answer.result == 1)
        }
        var extras: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let item = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if item.count == 2 { extras[item[0]] = item[1] }
            }
        }
        return LicenseResult(verified: true, validationTime: Int64(extras["VT"] ?? "") ?? 0, retryUntilTime: Int64(extras["GT"] ?? "") ?? 0,
                             retryAttempts: Int64(extras["GR"] ?? "") ?? 0, reason: "Google says this account is licensed")
    }
}

/// A license check's answer, out of Play's response envelope.
struct LicenseAnswer {
    let result: Int
    let signedData: String
    let signature: String

    init(result: Int, signedData: String, signature: String) {
        self.result = result
        self.signedData = signedData
        self.signature = signature
    }

    /// `GoogleApiResponse.payload(1).licenseV1Response(76)`.
    init?(protobuf: [UInt8]) {
        guard let payload = Protobuf.message(protobuf, field: 1), let response = Protobuf.message(payload, field: 76),
              let result = Protobuf.varint(response, field: 1), let signedData = Protobuf.message(response, field: 2),
              let signature = Protobuf.message(response, field: 3) else { return nil }
        self.init(result: Int(result), signedData: String(decoding: signedData, as: UTF8.self), signature: String(decoding: signature, as: UTF8.self))
    }
}

/// Reading the few protobuf fields wanted, skipping the rest.
enum Protobuf {
    private enum Value {
        case varint(UInt64)
        case bytes([UInt8])
        case other
    }

    private static func field(_ data: [UInt8], number wanted: Int) -> Value? {
        var position = 0
        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while position < data.count, shift < 64 {
                let byte = data[position]
                position += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while position < data.count {
            guard let tag = readVarint() else { return nil }
            let found: Value
            switch tag & 7 {
            case 0:
                guard let value = readVarint() else { return nil }
                found = .varint(value)
            case 1:
                position += 8
                found = .other
            case 2:
                guard let length = readVarint(), length <= UInt64(data.count - position) else { return nil }
                found = .bytes(Array(data[position..<(position + Int(length))]))
                position += Int(length)
            case 5:
                position += 4
                found = .other
            default:
                return nil
            }
            if Int(tag >> 3) == wanted { return found }
        }
        return nil
    }

    static func message(_ data: [UInt8], field number: Int) -> [UInt8]? {
        if case let .bytes(bytes)? = field(data, number: number) { return bytes }
        return nil
    }

    static func varint(_ data: [UInt8], field number: Int) -> UInt64? {
        if case let .varint(value)? = field(data, number: number) { return value }
        return nil
    }
}
