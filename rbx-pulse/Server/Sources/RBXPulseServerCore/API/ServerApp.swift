import Foundation
import Hummingbird
import Logging

/// Everything the HTTP layer and workers depend on. Tests build this with fakes.
public struct ServerDependencies: Sendable {
    public var store: any Store
    public var oauth: any RobloxOAuth
    public var box: SecretBox
    public var appCallbackURL: URL
    public var now: @Sendable () -> Date
    public var authRateLimit: Int

    public init(store: any Store, oauth: any RobloxOAuth, box: SecretBox, appCallbackURL: URL,
                authRateLimit: Int = 30, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.oauth = oauth
        self.box = box
        self.appCallbackURL = appCallbackURL
        self.authRateLimit = authRateLimit
        self.now = now
    }
}

public enum RBXPulseServerApp {
    /// The router with every route and middleware. Separate from `run` so tests drive it in-process.
    public static func buildRouter(_ deps: ServerDependencies) -> Router<AppRequestContext> {
        let router = Router(context: AppRequestContext.self)
        router.get("health") { _, _ in "ok" }

        let auth = AuthService(store: deps.store, oauth: deps.oauth, box: deps.box,
                               appCallbackURL: deps.appCallbackURL, now: deps.now)
        let authRoutes = AuthRoutes(auth: auth)
        authRoutes.addPublicRoutes(to: router,
                                   limiter: RateLimiter(limit: deps.authRateLimit, window: 60, now: deps.now))

        let authenticated = router.group().add(middleware: AuthMiddleware(auth: auth))
        authRoutes.addAuthenticatedRoutes(to: authenticated)
        return router
    }

    public static func run(config: ServerConfig) async throws {
        var logger = Logger(label: "rbxpulse")
        logger.logLevel = .info
        logger.info("Starting", metadata: ["config": "\(config)"])

        let deps = ServerDependencies(
            store: InMemoryStore(),
            oauth: RobloxOAuthClient(config: config.roblox, http: LiveHTTPExecutor()),
            box: try SecretBox(key: config.tokenEncryptionKey),
            appCallbackURL: config.appCallbackURL
        )
        let app = Application(router: buildRouter(deps),
                              configuration: .init(address: .hostname(config.host, port: config.port)),
                              logger: logger)
        try await app.runService()
    }
}
