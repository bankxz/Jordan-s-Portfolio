import Foundation
import PeakKit

public struct UserRecord: Sendable, Hashable, Codable {
    public var id: UUID
    /// Roblox `sub`; the stable identity (usernames change).
    public var robloxUserID: Int64
    public var username: String
    public var displayName: String
    public var createdAt: Date

    public init(id: UUID, robloxUserID: Int64, username: String, displayName: String, createdAt: Date) {
        self.id = id
        self.robloxUserID = robloxUserID
        self.username = username
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

/// One in-progress Roblox authorization. Single use; expires quickly.
public struct OAuthAttempt: Sendable, Hashable {
    public var state: String
    public var codeVerifier: String
    public var createdAt: Date

    public init(state: String, codeVerifier: String, createdAt: Date) {
        self.state = state
        self.codeVerifier = codeVerifier
        self.createdAt = createdAt
    }
}

/// The user's Roblox OAuth tokens, sealed with `SecretBox`.
public struct RobloxGrant: Sendable, Hashable {
    public var userID: UUID
    public var accessTokenSealed: Data
    public var refreshTokenSealed: Data
    /// Hash of the current refresh token; the compare-and-swap key for rotation.
    public var refreshTokenHash: String
    public var accessTokenExpiresAt: Date
    public var scopes: [String]
    public var universeIDs: [Int64]
    public var updatedAt: Date

    public init(userID: UUID, accessTokenSealed: Data, refreshTokenSealed: Data, refreshTokenHash: String,
                accessTokenExpiresAt: Date, scopes: [String], universeIDs: [Int64], updatedAt: Date) {
        self.userID = userID
        self.accessTokenSealed = accessTokenSealed
        self.refreshTokenSealed = refreshTokenSealed
        self.refreshTokenHash = refreshTokenHash
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.scopes = scopes
        self.universeIDs = universeIDs
        self.updatedAt = updatedAt
    }
}

/// An Peak app session. Tokens are stored only as SHA-256 hashes.
public struct SessionRecord: Sendable, Hashable {
    public var id: UUID
    /// All sessions descended from one sign-in share a family; reuse of a rotated refresh token
    /// revokes the whole family.
    public var familyID: UUID
    public var userID: UUID
    public var accessTokenHash: String
    public var accessExpiresAt: Date
    public var refreshTokenHash: String
    public var refreshExpiresAt: Date
    public var createdAt: Date
    public var rotatedAt: Date?
    public var revokedAt: Date?

    public init(id: UUID, familyID: UUID, userID: UUID, accessTokenHash: String, accessExpiresAt: Date,
                refreshTokenHash: String, refreshExpiresAt: Date, createdAt: Date,
                rotatedAt: Date? = nil, revokedAt: Date? = nil) {
        self.id = id
        self.familyID = familyID
        self.userID = userID
        self.accessTokenHash = accessTokenHash
        self.accessExpiresAt = accessExpiresAt
        self.refreshTokenHash = refreshTokenHash
        self.refreshExpiresAt = refreshExpiresAt
        self.createdAt = createdAt
        self.rotatedAt = rotatedAt
        self.revokedAt = revokedAt
    }

    public var isActive: Bool { rotatedAt == nil && revokedAt == nil }
}

/// Latest public metadata for a universe, from the games web API.
public struct GameInfo: Sendable, Hashable {
    public var universeID: Int64
    public var rootPlaceID: Int64
    public var name: String
    public var updatedAt: Date

    public init(universeID: Int64, rootPlaceID: Int64, name: String, updatedAt: Date) {
        self.universeID = universeID
        self.rootPlaceID = rootPlaceID
        self.name = name
        self.updatedAt = updatedAt
    }
}

public struct GameFlags: Sendable, Hashable {
    public var isFavourite: Bool
    public var isWorkingOn: Bool

    public init(isFavourite: Bool = false, isWorkingOn: Bool = false) {
        self.isFavourite = isFavourite
        self.isWorkingOn = isWorkingOn
    }
}

public struct MetricSample: Sendable, Hashable {
    public var universeID: Int64
    public var metric: Metric
    public var time: Date
    public var value: Double

    public init(universeID: Int64, metric: Metric, time: Date, value: Double) {
        self.universeID = universeID
        self.metric = metric
        self.time = time
        self.value = value
    }
}

public struct DeviceRecord: Sendable, Hashable {
    public var userID: UUID
    public var token: String
    public var sandbox: Bool
    public var updatedAt: Date
    /// IANA identifier reported by the app; schedules the morning briefing. `nil` from older app versions.
    public var timeZone: String?

    public init(userID: UUID, token: String, sandbox: Bool, updatedAt: Date, timeZone: String? = nil) {
        self.userID = userID
        self.token = token
        self.sandbox = sandbox
        self.updatedAt = updatedAt
        self.timeZone = timeZone
    }
}

public struct OwnedAlertRule: Sendable, Hashable {
    public var userID: UUID
    public var rule: AlertRule

    public init(userID: UUID, rule: AlertRule) {
        self.userID = userID
        self.rule = rule
    }
}

/// One Claude call, for the monthly budget and per-user daily limits. No prompt or answer text is stored.
public struct AIUsageRecord: Sendable, Hashable {
    /// `nil` once the user deleted their account; the spend still counts towards the month.
    public var userID: UUID?
    public var feature: String
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    /// Cost in millionths of a US dollar.
    public var costMicros: Int64
    public var time: Date

    public init(userID: UUID?, feature: String, model: String, inputTokens: Int, outputTokens: Int,
                costMicros: Int64, time: Date) {
        self.userID = userID
        self.feature = feature
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costMicros = costMicros
        self.time = time
    }
}

/// A daily Roblox Analytics value (retention, session length, crash rate…) for one universe.
public struct InsightSample: Sendable, Hashable {
    public var universeID: Int64
    public var metric: InsightMetric
    /// Start of the UTC day (or bucket) the value covers.
    public var time: Date
    public var value: Double

    public init(universeID: Int64, metric: InsightMetric, time: Date, value: Double) {
        self.universeID = universeID
        self.metric = metric
        self.time = time
        self.value = value
    }
}

/// Player counts per funnel step for one period, as logged by the game.
public struct FunnelSnapshot: Sendable, Hashable, Codable {
    public var universeID: Int64
    public var funnelName: String
    public var periodEnd: Date
    public var steps: [FunnelStep]

    public init(universeID: Int64, funnelName: String, periodEnd: Date, steps: [FunnelStep]) {
        self.universeID = universeID
        self.funnelName = funnelName
        self.periodEnd = periodEnd
        self.steps = steps
    }
}

/// A game's error-report key (decision 0008). Only the SHA-256 of the key is stored.
public struct IngestKeyRecord: Sendable, Hashable {
    public var userID: UUID
    public var universeID: Int64

    public init(userID: UUID, universeID: Int64) {
        self.userID = userID
        self.universeID = universeID
    }
}

public enum ErrorReportLimits {
    /// Distinct error signatures kept per game per UTC day; more are dropped, so a flood of junk can't grow storage.
    public static let signaturesPerDay = 500
    /// Highest count accepted for one entry in one report.
    public static let maxEntryCount = 10_000
    /// Error counts are kept for 30 days.
    public static let retention: TimeInterval = 30 * 86_400
}

/// A user's agreement to send their game data to one AI provider. Older rows, from before providers could be
/// chosen, were consents to Claude.
public struct AIConsent: Sendable, Hashable {
    public var consentedAt: Date
    /// `ServerConfig.AIProvider` raw value.
    public var provider: String

    public init(consentedAt: Date, provider: String) {
        self.consentedAt = consentedAt
        self.provider = provider
    }
}
