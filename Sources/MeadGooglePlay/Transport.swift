import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// How requests leave: a blocking call, as everything here runs on a thread
/// of its own. Tests supply their own.
public protocol HTTPTransport {
    func send(_ request: URLRequest) throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) throws -> HTTPResponse {
        let finished = DispatchSemaphore(value: 0)
        var outcome: Result<HTTPResponse, Error> = .failure(GooglePlayError.network("no response"))
        URLSession.shared.dataTask(with: request) { body, response, error in
            if let error {
                outcome = .failure(GooglePlayError.network(error.localizedDescription))
            } else if let response = response as? HTTPURLResponse {
                outcome = .success(HTTPResponse(status: response.statusCode, body: body ?? Data()))
            }
            finished.signal()
        }.resume()
        finished.wait()
        return try outcome.get()
    }
}

public enum GooglePlayError: Error, CustomStringConvertible {
    case network(String)
    case server(String)
    case badResponse(String)

    public var description: String {
        switch self {
        case let .network(detail): return "network error: \(detail)"
        case let .server(detail): return "Google said: \(detail)"
        case let .badResponse(detail): return "unexpected response: \(detail)"
        }
    }
}
