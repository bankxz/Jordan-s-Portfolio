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
        DataRoutes(builder: DashboardBuilder(store: deps.store, now: deps.now), store: deps.store, now: deps.now)
            .add(to: authenticated)
        return router
    }

    public static func run(config: ServerConfig) async throws {
        var logger = Logger(label: "rbxpulse")
        logger.logLevel = .info
        logger.info("Starting", metadata: ["config": "\(config)"])

        let http = LiveHTTPExecutor()
        let store: any Store = try await makeStore(config: config, logger: logger)
        let deps = ServerDependencies(
            store: store,
            oauth: RobloxOAuthClient(config: config.roblox, http: http),
            box: try SecretBox(key: config.tokenEncryptionKey),
            appCallbackURL: config.appCallbackURL
        )

        let push: any PushSender = try config.apns.map { try APNsSender(config: $0, http: http) } ?? DisabledPushSender()
        let alerts = AlertEvaluator(store: store, push: push, now: deps.now)
        let stats = StatsPoller(store: store, games: RobloxGamesClient(baseURL: config.roblox.gamesBaseURL, http: http),
                                alerts: alerts, now: deps.now)
        let tokens = RobloxTokenManager(store: store, oauth: deps.oauth, box: deps.box, now: deps.now)
        let revenue = RevenuePoller(store: store, tokens: tokens,
                                    analytics: RobloxAnalyticsClient(baseURL: config.roblox.apisBaseURL, http: http),
                                    now: deps.now)

        var app = Application(router: buildRouter(deps),
                              configuration: .init(address: .hostname(config.host, port: config.port)),
                              logger: logger)
        app.addServices(
            PeriodicService(name: "stats", interval: config.statsPollInterval, logger: logger) { try await stats.tick(logger: $0) },
            PeriodicService(name: "revenue", interval: config.revenuePollInterval, logger: logger) { try await revenue.tick(logger: $0) }
        )
        try await app.runService()
    }

    static func makeStore(config: ServerConfig, logger: Logger) async throws -> any Store {
        guard config.databaseURL != nil else {
            logger.warning("DATABASE_URL not set: using the in-memory store (data is lost on restart)")
            return InMemoryStore()
        }
        return InMemoryStore()  // Replaced by PostgresStore in the next slice.
    }
}
