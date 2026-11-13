import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Google Play's licensing service, as the Play Store runs it for the app
/// that asks: one request to Google for the signed-in account, and Google's
/// answer passed back as it came. Mead doesn't judge the answer: the app
/// verifies Google's signature itself, as it would on a phone. When Google
/// can't be asked, the answer is Play's "couldn't reach the server".
public struct LicenseRelay {
    /// Play's local error: the licensing server couldn't be reached (or
    /// nobody is signed in to ask it as).
    public static let errorContactingServer = 0x101
    /// Not licensed, as Play reports it when Google holds no license.
    public static let notLicensed = 0x1

    /// LVL's first protocol: Google's response code, and the text it signed
    /// with the game's key and its signature, when it answered.
    public struct V1 {
        public let code: Int
        public let signedData: String?
        public let signature: String?
        public let reason: String
    }

    /// LVL's second: the license Google issued, a JWT it signed, which Play
    /// hands to the app as LICENSE_DATA. Google issues one only to an account
    /// that holds a license.
    public struct V2 {
        public let code: Int
        public let jwt: String?
        public let reason: String
    }

    private let auth: GoogleAuth
    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
        auth = GoogleAuth(transport: transport)
    }

    public func checkV1(account: GoogleAccount?, packageName: String, versionCode: Int, nonce: Int64) -> V1 {
        let body: [UInt8]
        switch fetch(account: account, path: "checkLicense?pkgn=\(packageName)&vc=\(versionCode)&nnc=\(nonce)") {
        case .failure(let reason):
            return V1(code: Self.errorContactingServer, signedData: nil, signature: nil, reason: reason)
        case .success(let bytes):
            body = bytes
        }
        // GoogleApiResponse.payload(1).licenseV1Response(76).
        guard let answer = LicenseAnswer(protobuf: body) else {
            return V1(code: Self.errorContactingServer, signedData: nil, signature: nil, reason: "no license answer in Google's response")
        }
        return V1(code: answer.result, signedData: answer.signedData, signature: answer.signature,
                  reason: "Google answered code \(answer.result)")
    }

    public func checkV2(account: GoogleAccount?, packageName: String, versionCode: Int) -> V2 {
        let body: [UInt8]
        switch fetch(account: account, path: "checkLicenseServerFallback?pkgn=\(packageName)&vc=\(versionCode)") {
        case .failure(let reason):
            return V2(code: Self.errorContactingServer, jwt: nil, reason: reason)
        case .success(let bytes):
            body = bytes
        }
        // GoogleApiResponse.payload(1).licenseV2Response(173).license(1).jwt(1).
        guard let payload = Protobuf.message(body, field: 1), let response = Protobuf.message(payload, field: 173),
              let license = Protobuf.message(response, field: 1), let jwt = Protobuf.message(license, field: 1),
              !jwt.isEmpty else {
            return V2(code: Self.notLicensed, jwt: nil, reason: "Google issued no license to this account")
        }
        // Play reports code 0 with the license: the JWT is Google's to vouch
        // for, and the app's to verify.
        return V2(code: 0, jwt: String(decoding: jwt, as: UTF8.self), reason: "Google issued a license token")
    }

    private enum Fetched {
        case success([UInt8])
        case failure(String)
    }

    private func fetch(account: GoogleAccount?, path: String) -> Fetched {
        guard let account else { return .failure("not signed in to Google; run mead-google-login") }
        do {
            let token = try auth.playToken(for: account)
            var request = URLRequest(url: URL(string: "https://play-fe.googleapis.com/fdfe/apps/\(path)")!, timeoutInterval: 30)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(account.androidID, forHTTPHeaderField: "X-DFE-Device-Id")
            request.setValue("am-google", forHTTPHeaderField: "X-DFE-Client-Id")
            request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
            request.setValue("Android-Finsky/37.5.24-29 (api=3,sdk=35,device=mead,hardware=mead,product=mead,model=mead,buildId=mead,supportedAbis=arm64-v8a)", forHTTPHeaderField: "User-Agent")
            let response = try transport.send(request)
            guard response.status == 200 else { return .failure("Google's license server answered HTTP \(response.status)") }
            return .success([UInt8](response.body))
        } catch {
            return .failure("\(error)")
        }
    }
}
