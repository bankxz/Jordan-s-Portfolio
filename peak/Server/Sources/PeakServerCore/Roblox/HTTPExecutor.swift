import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

/// A plain outbound request. Every call to Roblox goes through `HTTPExecutor`, so tests can replay
/// recorded responses without a network.
public struct OutboundRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct OutboundResponse: Sendable, Hashable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol HTTPExecutor: Sendable {
    func execute(_ request: OutboundRequest) async throws -> OutboundResponse
}

/// AsyncHTTPClient-backed executor with a timeout and a response size cap.
public struct LiveHTTPExecutor: HTTPExecutor {
    private let client: HTTPClient
    private let timeout: TimeAmount
    private let maxResponseBytes: Int

    public init(client: HTTPClient = .shared, timeout: TimeAmount = .seconds(15), maxResponseBytes: Int = 4 * 1024 * 1024) {
        self.client = client
        self.timeout = timeout
        self.maxResponseBytes = maxResponseBytes
    }

    public func execute(_ request: OutboundRequest) async throws -> OutboundResponse {
        var outbound = HTTPClientRequest(url: request.url.absoluteString)
        outbound.method = HTTPMethod(rawValue: request.method)
        outbound.headers.add(name: "User-Agent", value: "Peak/1.0 (+https://peakstats.app)")
        for (name, value) in request.headers {
            outbound.headers.replaceOrAdd(name: name, value: value)
        }
        if let body = request.body {
            outbound.body = .bytes(ByteBuffer(bytes: body))
        }
        let response = try await client.execute(outbound, timeout: timeout)
        let buffer = try await response.body.collect(upTo: maxResponseBytes)
        var headers: [String: String] = [:]
        for header in response.headers { headers[header.name] = header.value }
        return OutboundResponse(status: Int(response.status.code), headers: headers, body: Data(buffer: buffer))
    }
}

enum FormEncoding {
    /// `application/x-www-form-urlencoded` with RFC 3986 unreserved characters left as-is.
    static func encode(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}
