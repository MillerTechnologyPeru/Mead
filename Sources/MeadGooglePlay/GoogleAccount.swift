import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Google account signed in on this machine. The token is as good as a
/// password for this device's access to Google Play: it is kept in a file only
/// the user can read, and is never logged.
public struct GoogleAccount: Codable {
    public let email: String
    public let masterToken: String
    /// The device's Android ID in hex. "1" when none has been issued.
    public let androidID: String

    public init(email: String, masterToken: String, androidID: String) {
        self.email = email
        self.masterToken = masterToken
        self.androidID = androidID
    }

    public static var defaultPath: String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
        return "\(home)/.mead/google/account.json"
    }

    public static func load(from path: String = defaultPath) -> GoogleAccount? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(GoogleAccount.self, from: data)
    }

    public func save(to path: String = defaultPath) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(self)
        // Made private before anything secret goes in it.
        let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else { throw GooglePlayError.badResponse("cannot write \(path)") }
        defer { close(descriptor) }
        fchmod(descriptor, 0o600)
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else { throw GooglePlayError.badResponse("cannot write \(path)") }
    }
}

/// Google's Android sign-in service, spoken as microG documents it. Mead says
/// plainly that it is "mead" wherever a device name is asked for.
public struct GoogleAuth {
    /// Signing in happens in a browser, here; this page leaves `oauth_token`
    /// among its cookies when it is done.
    public static let signInURL = "https://accounts.google.com/EmbeddedSetup"

    private static let endpoint = URL(string: "https://android.googleapis.com/auth")!
    private static let googleSignature = "38918a453d07199354f8b19af05ec6562ced5788"
    private static let playScope = "oauth2:https://www.googleapis.com/auth/googleplay"

    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// Trades the browser's one-time `oauth_token` for a lasting account.
    public func signIn(oauthToken: String, androidID: String = "1") throws -> GoogleAccount {
        let fields = try post([
            ("androidId", androidID),
            ("app", "com.google.android.gms"), ("client_sig", Self.googleSignature),
            ("callerPkg", "com.google.android.gms"), ("callerSig", Self.googleSignature),
            ("service", "ac2dm"), ("Token", oauthToken), ("ACCESS_TOKEN", "1"),
            ("add_account", "1"), ("get_accountid", "1"), ("droidguard_results", "null"),
        ], androidID: androidID)
        guard let token = fields["Token"], let email = fields["Email"] else {
            throw GooglePlayError.badResponse("no account in the sign-in response")
        }
        return GoogleAccount(email: email, masterToken: token, androidID: androidID)
    }

    /// A short-lived token for the Play store's servers.
    public func playToken(for account: GoogleAccount) throws -> String {
        let fields = try post([
            ("androidId", account.androidID), ("Email", account.email), ("Token", account.masterToken),
            ("app", "com.android.vending"), ("client_sig", Self.googleSignature),
            ("callerPkg", "com.android.vending"), ("callerSig", Self.googleSignature),
            ("service", Self.playScope), ("has_permission", "1"),
            ("is_called_from_account_manager", "1"), ("_opt_is_called_from_account_manager", "1"),
        ], androidID: account.androidID)
        guard let token = fields["Auth"] else {
            throw GooglePlayError.badResponse("no token in the auth response")
        }
        return token
    }

    private func post(_ specific: [(String, String)], androidID: String) throws -> [String: String] {
        let common = [("accountType", "HOSTED_OR_GOOGLE"), ("source", "android"), ("sdk_version", "35"),
                      ("lang", "en_US"), ("device_country", "us"), ("google_play_services_version", "250932000")]
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("GoogleAuth/1.4 (mead mead); gzip", forHTTPHeaderField: "User-Agent")
        request.setValue(androidID, forHTTPHeaderField: "device")
        request.httpBody = Data(Self.formEncoded(common + specific).utf8)
        let response = try transport.send(request)
        let fields = Self.parseFields(String(decoding: response.body, as: UTF8.self))
        guard response.status == 200 else {
            throw GooglePlayError.server(fields["Error"] ?? "HTTP \(response.status)")
        }
        return fields
    }

    static func formEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func escaped(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return fields.map { "\(escaped($0.0))=\(escaped($0.1))" }.joined(separator: "&")
    }

    /// The service answers with `key=value` lines.
    static func parseFields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return fields
    }
}
