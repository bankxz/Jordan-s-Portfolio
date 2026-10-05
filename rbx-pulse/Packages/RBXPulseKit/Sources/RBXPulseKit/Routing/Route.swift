import Foundation

/// Every destination reachable from outside the app: widgets, notifications, Live Activities,
/// App Intents and the OAuth callback. One parser means one place to validate untrusted URLs.
public enum Route: Hashable, Sendable {
    case home
    case games
    case game(id: Int64)
    case goals
    case goal(id: UUID)
    case alerts
    case campaign(id: String)
    /// Backend redirect after Roblox OAuth, carrying a one-time session code.
    case authComplete(code: String)

    public static let scheme = "rbxpulse"

    /// Parses `rbxpulse://<host>/<path>` URLs. Returns `nil` for anything unexpected rather than
    /// guessing, because these URLs can come from any app or web page.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }

        switch (host, parts.count) {
        case ("home", 0): self = .home
        case ("games", 0): self = .games
        case ("game", 1):
            let raw = parts[0]
            guard raw.allSatisfy({ $0.isASCII && $0.isNumber }), let id = Int64(raw), id > 0 else { return nil }
            self = .game(id: id)
        case ("goals", 0): self = .goals
        case ("goal", 1):
            guard let id = UUID(uuidString: parts[0]) else { return nil }
            self = .goal(id: id)
        case ("alerts", 0): self = .alerts
        case ("campaign", 1):
            let id = parts[0]
            guard id.isEmpty == false, id.count <= 64,
                  id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
                  id.allSatisfy(\.isASCII) else { return nil }
            self = .campaign(id: id)
        case ("auth", 1) where parts[0] == "complete":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let codes = items.filter { $0.name == "code" }.compactMap(\.value)
            guard codes.count == 1, let code = codes.first, code.isEmpty == false, code.count <= 512 else {
                return nil
            }
            self = .authComplete(code: code)
        default:
            return nil
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .home: components.host = "home"
        case .games: components.host = "games"
        case .game(let id): components.host = "game"; components.path = "/\(id)"
        case .goals: components.host = "goals"
        case .goal(let id): components.host = "goal"; components.path = "/\(id.uuidString)"
        case .alerts: components.host = "alerts"
        case .campaign(let id): components.host = "campaign"; components.path = "/\(id)"
        case .authComplete(let code):
            components.host = "auth"
            components.path = "/complete"
            components.queryItems = [URLQueryItem(name: "code", value: code)]
        }
        // All components are validated or generated above, so this cannot fail.
        return components.url!
    }
}
