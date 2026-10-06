import Foundation

/// Everything the server needs from its environment. Secrets come only from the environment and are
/// never logged; `description` redacts them.
public struct ServerConfig: Sendable, CustomStringConvertible {
    public struct Roblox: Sendable {
        public var clientID: String
        public var clientSecret: String
        /// Must exactly match a redirect URL registered for the Roblox OAuth app.
        public var redirectURI: URL
        public var scopes: [String]
        public var oauthBaseURL: URL
        public var apisBaseURL: URL
        public var gamesBaseURL: URL

        public init(
            clientID: String,
            clientSecret: String,
            redirectURI: URL,
            scopes: [String] = ["openid", "profile", "universe.analytics:read"],
            oauthBaseURL: URL = URL(string: "https://apis.roblox.com/oauth/")!,
            apisBaseURL: URL = URL(string: "https://apis.roblox.com/")!,
            gamesBaseURL: URL = URL(string: "https://games.roblox.com/")!
        ) {
            self.clientID = clientID
            self.clientSecret = clientSecret
            self.redirectURI = redirectURI
            self.scopes = scopes
            self.oauthBaseURL = oauthBaseURL
            self.apisBaseURL = apisBaseURL
            self.gamesBaseURL = gamesBaseURL
        }
    }

    public struct APNs: Sendable {
        public var teamID: String
        public var keyID: String
        /// Contents of the `.p8` key file (PEM).
        public var privateKeyPEM: String
        public var bundleID: String

        public init(teamID: String, keyID: String, privateKeyPEM: String, bundleID: String) {
            self.teamID = teamID
            self.keyID = keyID
            self.privateKeyPEM = privateKeyPEM
            self.bundleID = bundleID
        }
    }

    public var host: String
    public var port: Int
    public var roblox: Roblox
    /// Where the app receives the one-time session code after OAuth.
    public var appCallbackURL: URL
    /// 32-byte key (base64) used to encrypt Roblox tokens at rest.
    public var tokenEncryptionKey: Data
    /// `nil` → in-memory store (development and tests only).
    public var databaseURL: String?
    /// `nil` → pushes disabled.
    public var apns: APNs?
    public var statsPollInterval: Duration
    public var revenuePollInterval: Duration

    public init(
        host: String = "0.0.0.0",
        port: Int = 8080,
        roblox: Roblox,
        appCallbackURL: URL = URL(string: "peakstats://auth/complete")!,
        tokenEncryptionKey: Data,
        databaseURL: String? = nil,
        apns: APNs? = nil,
        statsPollInterval: Duration = .seconds(60),
        revenuePollInterval: Duration = .seconds(15 * 60)
    ) {
        self.host = host
        self.port = port
        self.roblox = roblox
        self.appCallbackURL = appCallbackURL
        self.tokenEncryptionKey = tokenEncryptionKey
        self.databaseURL = databaseURL
        self.apns = apns
        self.statsPollInterval = statsPollInterval
        self.revenuePollInterval = revenuePollInterval
    }

    public enum ConfigError: Error, CustomStringConvertible, Equatable {
        case missing(String)
        case invalid(String, reason: String)

        public var description: String {
            switch self {
            case .missing(let key): "Missing required environment variable \(key)"
            case .invalid(let key, let reason): "Invalid \(key): \(reason)"
            }
        }
    }

    /// Reads configuration from environment variables. See Server/README.md for the full list.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> ServerConfig {
        func required(_ key: String) throws -> String {
            guard let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else {
                throw ConfigError.missing(key)
            }
            return value
        }
        func url(_ key: String, _ raw: String) throws -> URL {
            guard let url = URL(string: raw), url.scheme != nil else { throw ConfigError.invalid(key, reason: "not a URL") }
            return url
        }

        let redirect = try url("ROBLOX_REDIRECT_URI", required("ROBLOX_REDIRECT_URI"))
        guard redirect.scheme == "https" || redirect.host == "localhost" else {
            throw ConfigError.invalid("ROBLOX_REDIRECT_URI", reason: "must be https (or localhost for development)")
        }
        guard let key = Data(base64Encoded: try required("TOKEN_ENCRYPTION_KEY")), key.count == 32 else {
            throw ConfigError.invalid("TOKEN_ENCRYPTION_KEY", reason: "must be 32 bytes, base64-encoded")
        }

        var apns: APNs?
        if let keyPEM = env["APNS_PRIVATE_KEY"], keyPEM.isEmpty == false {
            apns = APNs(teamID: try required("APNS_TEAM_ID"), keyID: try required("APNS_KEY_ID"),
                        privateKeyPEM: keyPEM.replacingOccurrences(of: "\\n", with: "\n"),
                        bundleID: env["APNS_BUNDLE_ID"] ?? "com.peakstats.app")
        }

        let port: Int
        if let raw = env["PORT"] {
            guard let parsed = Int(raw), (1...65_535).contains(parsed) else {
                throw ConfigError.invalid("PORT", reason: "must be 1–65535")
            }
            port = parsed
        } else {
            port = 8080
        }

        return ServerConfig(
            host: env["HOST"] ?? "0.0.0.0",
            port: port,
            roblox: Roblox(clientID: try required("ROBLOX_CLIENT_ID"),
                           clientSecret: try required("ROBLOX_CLIENT_SECRET"),
                           redirectURI: redirect),
            appCallbackURL: try url("APP_CALLBACK_URL", env["APP_CALLBACK_URL"] ?? "peakstats://auth/complete"),
            tokenEncryptionKey: key,
            databaseURL: env["DATABASE_URL"].flatMap { $0.isEmpty ? nil : $0 },
            apns: apns
        )
    }

    public var description: String {
        "ServerConfig(host: \(host), port: \(port), robloxClientID: \(roblox.clientID), redirect: \(roblox.redirectURI), "
            + "secret: <redacted>, encryptionKey: <redacted>, database: \(databaseURL == nil ? "in-memory" : "postgres"), "
            + "apns: \(apns == nil ? "disabled" : "enabled"))"
    }
}
