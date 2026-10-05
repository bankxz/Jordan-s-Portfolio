import Foundation
import Hummingbird
import NIOCore
import RBXPulseKit

/// Per-request context: the caller's address (for rate limits) and, after `AuthMiddleware`, who they are.
public struct AppRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    public let remoteAddress: SocketAddress?
    public var auth: AuthService.Authenticated?

    public init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
        self.remoteAddress = source.channel.remoteAddress
        self.auth = nil
    }

    /// The signed-in user; only valid on routes behind `AuthMiddleware`.
    public func requireAuth() throws -> AuthService.Authenticated {
        guard let auth else { throw APIFailure.unauthorized }
        return auth
    }

    /// Bounded request size for JSON bodies.
    public var maxUploadSize: Int { 64 * 1024 }
}

/// Errors returned to clients as `{"error": "<code>"}` (the shape of `BackendAPI.ErrorBody`).
/// Codes are stable, short and never include internal details.
public enum APIFailure: Error, HTTPResponseError, Equatable {
    case badRequest(String)
    case unauthorized
    case notFound
    case rateLimited(retryAfter: Int)
    case upstreamUnavailable
    case reconnectRequired

    public var status: HTTPResponse.Status {
        switch self {
        case .badRequest: .badRequest
        case .unauthorized: .unauthorized
        case .notFound: .notFound
        case .rateLimited: .tooManyRequests
        case .upstreamUnavailable: .badGateway
        case .reconnectRequired: .conflict
        }
    }

    var code: String {
        switch self {
        case .badRequest(let code): code
        case .unauthorized: "unauthorized"
        case .notFound: "not_found"
        case .rateLimited: "rate_limited"
        case .upstreamUnavailable: "upstream_unavailable"
        case .reconnectRequired: "reconnect_required"
        }
    }

    public func response(from request: Request, context: some RequestContext) throws -> Response {
        var response = try JSONBody.response(BackendAPI.ErrorBody(error: code), status: status)
        if case .rateLimited(let seconds) = self {
            response.headers[.retryAfter] = String(seconds)
        }
        if case .unauthorized = self {
            response.headers[.wwwAuthenticate] = "Bearer"
        }
        return response
    }
}

/// JSON with the same encoder/decoder settings as the app (`JSONCoding`), so dates round-trip exactly.
public enum JSONBody {
    public static func response(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try JSONCoding.makeEncoder().encode(value)
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        headers[.cacheControl] = "no-store"
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    public static func decode<T: Decodable>(_ type: T.Type, from request: Request, context: AppRequestContext) async throws -> T {
        let buffer = try await request.body.collect(upTo: context.maxUploadSize)
        do {
            return try JSONCoding.makeDecoder().decode(T.self, from: Data(buffer: buffer))
        } catch {
            throw APIFailure.badRequest("invalid_body")
        }
    }

    public static func noContent() -> Response {
        Response(status: .noContent)
    }
}

/// Fixed-window limiter keyed by client address. Protects the unauthenticated auth endpoints from
/// brute force and abuse (roblox-security: rate-limit every entry point).
public actor RateLimiter {
    private let limit: Int
    private let window: TimeInterval
    private let now: @Sendable () -> Date
    private var buckets: [String: (windowStart: Date, count: Int)] = [:]

    public init(limit: Int, window: TimeInterval, now: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = limit
        self.window = window
        self.now = now
    }

    /// Returns `nil` when allowed, otherwise seconds until the window resets.
    public func check(key: String) -> Int? {
        let current = now()
        if buckets.count > 50_000 {
            buckets = buckets.filter { current.timeIntervalSince($0.value.windowStart) < window }
        }
        var bucket = buckets[key] ?? (current, 0)
        if current.timeIntervalSince(bucket.windowStart) >= window {
            bucket = (current, 0)
        }
        bucket.count += 1
        buckets[key] = bucket
        guard bucket.count <= limit else {
            return max(1, Int((window - current.timeIntervalSince(bucket.windowStart)).rounded(.up)))
        }
        return nil
    }
}

struct RateLimitMiddleware: RouterMiddleware {
    typealias Context = AppRequestContext
    let limiter: RateLimiter

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let key = context.remoteAddress?.ipAddress ?? "unknown"
        if let retryAfter = await limiter.check(key: key) {
            throw APIFailure.rateLimited(retryAfter: retryAfter)
        }
        return try await next(request, context)
    }
}

/// Requires `Authorization: Bearer <access token>` and records who the caller is.
struct AuthMiddleware: RouterMiddleware {
    typealias Context = AppRequestContext
    let auth: AuthService

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer ") else {
            throw APIFailure.unauthorized
        }
        let token = String(header.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
        do {
            var context = context
            context.auth = try await auth.authenticate(accessToken: token)
            return try await next(request, context)
        } catch is SessionError {
            throw APIFailure.unauthorized
        }
    }
}
