import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum APIError: Error, Hashable, Sendable {
    /// Still 401 after one refresh-and-retry.
    case unauthorized
    case forbidden
    case notFound
    /// 429. `retryAfter` comes from the `Retry-After` header when present.
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case unexpectedStatus(Int)
    case decoding(String)
}

public enum HTTPMethod: String, Sendable {
    case get = "GET", post = "POST", put = "PUT", delete = "DELETE"
}

/// A typed backend endpoint.
public struct Endpoint<Response: Decodable & Sendable>: Sendable {
    public var method: HTTPMethod
    public var path: String
    public var queryItems: [URLQueryItem]
    public var body: Data?
    public var requiresAuth: Bool

    public init(method: HTTPMethod = .get, path: String, queryItems: [URLQueryItem] = [],
                body: Data? = nil, requiresAuth: Bool = true) {
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.body = body
        self.requiresAuth = requiresAuth
    }
}

/// Empty response body for endpoints that return 204.
public struct NoContent: Decodable, Sendable, Hashable {
    public init() {}
}

public enum JSONCoding {
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// Talks to the RBX Pulse backend. Attaches the session token, and on a 401 asks the coordinator
/// for a fresh token and retries exactly once.
public struct APIClient: Sendable {
    public let baseURL: URL
    private let transport: any HTTPTransport
    private let auth: AuthSessionCoordinator?

    public init(baseURL: URL, transport: any HTTPTransport, auth: AuthSessionCoordinator?) {
        self.baseURL = baseURL
        self.transport = transport
        self.auth = auth
    }

    public func send<Response>(_ endpoint: Endpoint<Response>) async throws -> Response {
        var token: String?
        if endpoint.requiresAuth {
            guard let auth else { throw AuthError.signedOut }
            token = try await auth.validAccessToken()
        }

        var (data, response) = try await transport.send(makeRequest(endpoint, token: token))

        if response.statusCode == 401, endpoint.requiresAuth, let auth, let failed = token {
            let retryToken = try await auth.accessTokenAfterUnauthorized(failedAccessToken: failed)
            (data, response) = try await transport.send(makeRequest(endpoint, token: retryToken))
        }

        try Self.validate(response)

        if Response.self == NoContent.self, let empty = NoContent() as? Response {
            return empty
        }
        do {
            return try JSONCoding.makeDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    func makeRequest<Response>(_ endpoint: Endpoint<Response>, token: String?) throws -> URLRequest {
        let trimmedPath = endpoint.path.hasPrefix("/") ? String(endpoint.path.dropFirst()) : endpoint.path
        guard var components = URLComponents(url: baseURL.appendingPathComponent(trimmedPath),
                                             resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if endpoint.queryItems.isEmpty == false {
            components.queryItems = endpoint.queryItems
        }
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = endpoint.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound
        case 429:
            let header = response.value(forHTTPHeaderField: "Retry-After")
            let seconds = header.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            throw APIError.rateLimited(retryAfter: seconds.flatMap { $0 >= 0 ? $0 : nil })
        case 500..<600:
            throw APIError.server(status: response.statusCode)
        default:
            throw APIError.unexpectedStatus(response.statusCode)
        }
    }
}
