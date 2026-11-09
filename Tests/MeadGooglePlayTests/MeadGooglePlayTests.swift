import Foundation
@testable import MeadCrypto
@testable import MeadGooglePlay
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Google's servers are played by a fake here: the responses are signed with a
// throwaway OpenSSL key, as the real ones are with the game's.

private let publicKey = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqRUeBTLFPAKdnvYo0lDLwoKtaq1wOXELQ51QXHaI09OualH89qRTsL1/dc7yD7FwcrtyFAyxaX3N7pKsSIkE3zOnNX80+WK4eOHrY+VzPEcXEIoLXYKdSYAsijlHQd1JpM7tiKTBPnpUfBAJEvU90n8ReOTQsWIRwsqQHMAuhC6aA2Sh9GdJIqOqVnN5DEf8dOl22vG+B/Lw8OlmYcpb4mVkOYMX7eWqw+uWrcR1Dw3wGkWewF5T/4F05bXJqt+kcJHKNZ5c2UzpM6m02oaf7HXqodMDnY3M0GT3YTtXfxgCWuZFrgrXxl4qtsPOL0Ur9fAyqDYWywo7jpi+NcfK6wIDAQAB"
private let licensedData = "0|123|com.example.game|7|user|1700000000:VT=1800000000000&GT=1900000000000&GR=10"
private let licensedSignature = "aVd/6l5SUQH7Xc40iWjBuc28I9wqcKSnE+dzs1XaNEzXcN+sOtU8erIOkGtKUVMLZFVRveiqy4sLlI6MiOu0o9/Bbo8W00QnElNE4BqCh4cyTwpbiH5ro514dLJm0roercYJSOF2RjS4wTV/bKBNj7XpZd6YGSW1Ee97ZkdRlTxopbLKSQLhGtMpS9YS7zRLQ8Vbx4ao8tIiwkQ8GmwyB+yh8eCTrNJ1ft4wZiG6ciJpwdLVt97hf2U1TN/yfrdKtUZkN14GhMygjfNP9uvb3vVgvzGYvRksrEG86s8HBjn//WCIt8TSyrq1kQbLnqzHauN6SkySRBuVx8AzXqBaUQ=="
private let notLicensedData = "1|123|com.example.game|7|user|1700000000"
private let notLicensedSignature = "TFRb4p7HfmfzwXvN2vxrdpiExI0kku+bmoYYe3nyKbMLIzV2FjfRIUB7VWi2Uu1uqZvRMEEdEMurODpT3wLnOxmEIjvMTRqV9I7pvSM4ivui4x4uRwN6/NEZ4+KDo+KIBYSQ0aLmxlpjbdJ2rtyAwgjbmZuhQQFSUPZjzb75eryp7OCI5GGx2pFrHg/IsT9vPSJu7v9jfSxMApdugoz5rN75o9P913MsaRDSV/QFZ3n3zVjJJSqHdJGwX/C0Te8I4r+fwjiB51g8tQFr2kDNNr5Gz4WM+yIjXtB5NW7OSYjNQ6tWhtl+B2LcNv4Z2nqeg7yJR0Hvw4wHQqptTYmqXw=="

private func evaluate(_ answer: LicenseAnswer, nonce: Int32 = 123, package: String = "com.example.game", version: Int = 7, key: String = publicKey) -> LicenseResult {
    GooglePlayLicense.evaluate(answer, packageName: package, versionCode: version, nonce: nonce, publicKey: key)
}

@Test func sha1MatchesItsPublishedVectors() {
    func hex(_ bytes: [UInt8]) -> String { bytes.map { String(UInt($0) + 0x100, radix: 16).dropFirst() }.joined() }
    #expect(hex(SHA1.hash(Array("abc".utf8))) == "a9993e364706816aba3e25717850c26c9cd0d89d")
    #expect(hex(SHA1.hash([])) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    #expect(hex(SHA1.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))) == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
}

@Test func aLicensedResponseVerifiesAndCarriesItsTerms() {
    let result = evaluate(LicenseAnswer(result: 0, signedData: licensedData, signature: licensedSignature))
    #expect(result.verified)
    #expect(result.validationTime == 1_800_000_000_000)
    #expect(result.retryUntilTime == 1_900_000_000_000)
    #expect(result.retryAttempts == 10)
}

@Test func aNotLicensedResponseIsNotVerifiedEvenWhenItsSignatureIsGood() {
    #expect(!evaluate(LicenseAnswer(result: 1, signedData: notLicensedData, signature: notLicensedSignature)).verified)
}

@Test func tamperingOrAReplayIsNotVerified() {
    #expect(!evaluate(LicenseAnswer(result: 0, signedData: licensedData + "x", signature: licensedSignature)).verified, "changed text")
    #expect(!evaluate(LicenseAnswer(result: 0, signedData: notLicensedData, signature: licensedSignature)).verified, "another response's signature")
    #expect(!evaluate(LicenseAnswer(result: 1, signedData: licensedData, signature: licensedSignature)).verified, "result differs from the signed text")
    #expect(!evaluate(LicenseAnswer(result: 0, signedData: licensedData, signature: licensedSignature), nonce: 124).verified, "another nonce")
    #expect(!evaluate(LicenseAnswer(result: 0, signedData: licensedData, signature: licensedSignature), package: "com.other").verified, "another package")
    #expect(!evaluate(LicenseAnswer(result: 0, signedData: licensedData, signature: licensedSignature), version: 8).verified, "another version")
    #expect(!evaluate(LicenseAnswer(result: 0, signedData: licensedData, signature: licensedSignature), key: "AAAA").verified, "unreadable key")
}

private func varint(_ value: UInt64) -> [UInt8] {
    var value = value, out: [UInt8] = []
    repeat {
        var byte = UInt8(value & 0x7f)
        value >>= 7
        if value != 0 { byte |= 0x80 }
        out.append(byte)
    } while value != 0
    return out
}

private func bytesField(_ number: UInt64, _ content: [UInt8]) -> [UInt8] { varint(number << 3 | 2) + varint(UInt64(content.count)) + content }

private func playResponse(result: UInt64, signedData: String, signature: String) -> Data {
    let answer = varint(1 << 3) + varint(result) + bytesField(2, Array(signedData.utf8)) + bytesField(3, Array(signature.utf8))
    // A field before the one wanted, to be skipped.
    let payload = bytesField(2, [1, 2, 3]) + bytesField(76, answer)
    return Data(bytesField(1, payload))
}

private final class FakeGoogle: HTTPTransport {
    var requests: [URLRequest] = []
    var authStatus = 200
    var licenseBody = playResponse(result: 0, signedData: licensedData, signature: licensedSignature)

    func send(_ request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        if request.url?.host == "android.googleapis.com" {
            return authStatus == 200 ? HTTPResponse(status: 200, body: Data("Auth=play-token\nExpiry=1\n".utf8))
                : HTTPResponse(status: authStatus, body: Data("Error=BadAuthentication\n".utf8))
        }
        return HTTPResponse(status: 200, body: licenseBody)
    }
}

private let account = GoogleAccount(email: "someone@example.com", masterToken: "aas_et/secret", androidID: "abc")

@Test func aCheckAsksGoogleWithThePlayToken() {
    let google = FakeGoogle()
    let result = GooglePlayLicense(transport: google).check(account: account, packageName: "com.example.game", versionCode: 7, publicKey: publicKey, nonce: 123)
    #expect(result.verified)
    #expect(google.requests.count == 2)
    #expect(google.requests[1].url?.absoluteString == "https://play-fe.googleapis.com/fdfe/apps/checkLicense?pkgn=com.example.game&vc=7&nnc=123")
    #expect(google.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer play-token")
    #expect(google.requests[1].value(forHTTPHeaderField: "X-DFE-Device-Id") == "abc")
}

@Test func noAccountOrAFailedSignInIsUnverifiedAndAsksNothing() {
    let google = FakeGoogle()
    #expect(!GooglePlayLicense(transport: google).check(account: nil, packageName: "p", versionCode: 1, publicKey: publicKey).verified)
    #expect(google.requests.isEmpty)
    google.authStatus = 403
    let result = GooglePlayLicense(transport: google).check(account: account, packageName: "p", versionCode: 1, publicKey: publicKey)
    #expect(!result.verified)
    #expect(result.reason.contains("BadAuthentication"))
}

@Test func aResponseWithNoLicenseIsUnverified() {
    let google = FakeGoogle()
    google.licenseBody = Data([0x0a, 0x00])
    #expect(!GooglePlayLicense(transport: google).check(account: account, packageName: "com.example.game", versionCode: 7, publicKey: publicKey, nonce: 123).verified)
}

@Test func signingInStoresWhatGoogleReturns() throws {
    final class Answer: HTTPTransport {
        var body = ""
        func send(_ request: URLRequest) throws -> HTTPResponse {
            body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            return HTTPResponse(status: 200, body: Data("Token=aas_et/new\nEmail=someone@example.com\n".utf8))
        }
    }
    let transport = Answer()
    let signedIn = try GoogleAuth(transport: transport).signIn(oauthToken: "oauth2_4/a+b", androidID: "abc")
    #expect(signedIn.email == "someone@example.com")
    #expect(signedIn.masterToken == "aas_et/new")
    #expect(transport.body.contains("Token=oauth2_4%2Fa%2Bb"))
    #expect(transport.body.contains("ACCESS_TOKEN=1"))

    let path = NSTemporaryDirectory() + "mead-account-\(UUID().uuidString)/account.json"
    try signedIn.save(to: path)
    #expect(GoogleAccount.load(from: path)?.masterToken == "aas_et/new")
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600, "only its owner may read it")
    try FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
}

@Test func aCompiledManifestGivesItsPackageAndVersion() throws {
    func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
    func u32(_ v: Int) -> [UInt8] { u16(v & 0xffff) + u16(v >> 16 & 0xffff) }
    let names = ["manifest", "package", "versionCode", "com.example.game"]
    var content: [UInt8] = [], offsets: [UInt8] = []
    for name in names {
        offsets += u32(content.count)
        content += u16(name.utf16.count) + name.utf16.flatMap { u16(Int($0)) } + u16(0)
    }
    while content.count % 4 != 0 { content.append(0) }
    let poolSize = 28 + offsets.count + content.count
    let pool = u16(1) + u16(28) + u32(poolSize) + u32(names.count) + u32(0) + u32(0) + u32(28 + offsets.count) + u32(0) + offsets + content
    func attribute(_ name: Int, raw: Int, data: Int) -> [UInt8] { u32(0xffffffff) + u32(name) + u32(raw) + u16(8) + [0, 16] + u32(data) }
    let attributes = attribute(2, raw: 0xffffffff, data: 972_111_401) + attribute(1, raw: 3, data: 3)
    let element = u16(0x102) + u16(16) + u32(36 + attributes.count) + u32(1) + u32(0xffffffff) + u32(0xffffffff) + u32(0) + u16(20) + u16(20) + u16(2) + u16(0) + u16(0) + u16(0) + attributes
    let body = pool + element
    let manifest = try #require(AndroidManifest(binary: u16(3) + u16(8) + u32(8 + body.count) + body))
    #expect(manifest.packageName == "com.example.game")
    #expect(manifest.versionCode == 972_111_401)
}
