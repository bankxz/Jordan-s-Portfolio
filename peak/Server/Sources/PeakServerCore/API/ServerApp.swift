import Foundation
import Hummingbird
import Logging
import PostgresNIO

/// Everything the HTTP layer and workers depend on. Tests build this with fakes.
public struct ServerDependencies: Sendable {
    public var store: any Store
    public var oauth: any RobloxOAuth
    public var box: SecretBox
    public var appCallbackURL: URL
    public var now: @Sendable () -> Date
    public var authRateLimit: Int
    /// `nil` → AI wording off (deterministic insights still served).
    public var claude: (any ClaudeAPI)?
    public var aiSettings: AIService.Settings?

    public init(store: any Store, oauth: any RobloxOAuth, box: SecretBox, appCallbackURL: URL,
                authRateLimit: Int = 30, claude: (any ClaudeAPI)? = nil, aiSettings: AIService.Settings? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.oauth = oauth
        self.box = box
        self.appCallbackURL = appCallbackURL
        self.authRateLimit = authRateLimit
        self.claude = claude
        self.aiSettings = aiSettings
        self.now = now
    }
}

public enum PeakServerApp {
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
        let dashboard = DashboardBuilder(store: deps.store, now: deps.now)
        DataRoutes(builder: dashboard, store: deps.store, now: deps.now).add(to: authenticated)
        let ai = AIService(store: deps.store, claude: deps.aiSettings == nil ? nil : deps.claude,
                           settings: deps.claude == nil ? nil : deps.aiSettings, now: deps.now)
        InsightRoutes(insights: InsightBuilder(store: deps.store, dashboard: dashboard, now: deps.now),
                      dashboard: dashboard, ai: ai, cache: NarrationCache(), now: deps.now)
            .add(to: authenticated)
        return router
    }

    public static func run(config: ServerConfig) async throws {
        var logger = Logger(label: "peak")
        logger.logLevel = .info
        logger.info("Starting", metadata: ["config": "\(config)"])

        let http = LiveHTTPExecutor()
        let postgres: PostgresClient?
        let store: any Store
        if let databaseURL = config.databaseURL {
            let client = PostgresClient(configuration: try PostgresStore.configuration(url: databaseURL), backgroundLogger: logger)
            postgres = client
            store = PostgresStore(client: client, logger: logger)
        } else {
            logger.warning("DATABASE_URL not set: using the in-memory store (data is lost on restart)")
            postgres = nil
            store = InMemoryStore()
        }
        // Claude responses with thinking can take a while; give them their own, longer timeout.
        let claude = config.ai.map {
            ClaudeClient(apiKey: $0.apiKey, baseURL: $0.baseURL,
                         http: LiveHTTPExecutor(timeout: .seconds(120), maxResponseBytes: 2 * 1024 * 1024))
        }
        let deps = ServerDependencies(
            store: store,
            oauth: RobloxOAuthClient(config: config.roblox, http: http),
            box: try SecretBox(key: config.tokenEncryptionKey),
            appCallbackURL: config.appCallbackURL,
            claude: claude,
            aiSettings: config.ai.map(AIService.Settings.init)
        )

        let push: any PushSender = try config.apns.map { try APNsSender(config: $0, http: http) } ?? DisabledPushSender()
        let alerts = AlertEvaluator(store: store, push: push, now: deps.now)
        let stats = StatsPoller(store: store, games: RobloxGamesClient(baseURL: config.roblox.gamesBaseURL, http: http),
                                alerts: alerts, now: deps.now)
        let tokens = RobloxTokenManager(store: store, oauth: deps.oauth, box: deps.box, now: deps.now)
        let analyticsClient = RobloxAnalyticsClient(baseURL: config.roblox.apisBaseURL, http: http)
        let revenue = RevenuePoller(store: store, tokens: tokens, analytics: analyticsClient, now: deps.now)
        let dailyAnalytics = AnalyticsPoller(store: store, tokens: tokens, analytics: analyticsClient, now: deps.now)

        var app = Application(router: buildRouter(deps),
                              configuration: .init(address: .hostname(config.host, port: config.port)),
                              logger: logger)
        if let postgres, let pgStore = store as? PostgresStore {
            // The client must be running before migrations; services start before the server accepts traffic.
            app.addServices(postgres)
            app.beforeServerStarts { try await pgStore.migrate() }
        }
        app.addServices(
            PeriodicService(name: "stats", interval: config.statsPollInterval, initialDelay: .seconds(5), logger: logger) { try await stats.tick(logger: $0) },
            PeriodicService(name: "revenue", interval: config.revenuePollInterval, initialDelay: .seconds(30), logger: logger) { try await revenue.tick(logger: $0) },
            // Daily metrics change once a day; every 6 hours catches Roblox's late revisions.
            PeriodicService(name: "analytics", interval: .seconds(6 * 3_600), initialDelay: .seconds(90), logger: logger) { try await dailyAnalytics.tick(logger: $0) }
        )
        try await app.runService()
    }
}
