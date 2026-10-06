import Foundation
import PeakKit

/// Persistence for the server. Two implementations: `InMemoryStore` (tests, local dev) and
/// `PostgresStore` (production). Both must pass `StoreContractTests`.
///
/// Methods documented as atomic are what the security model relies on: single-use OAuth attempts and
/// session codes, compare-and-swap Roblox token rotation, and refresh-token rotation that can only
/// succeed once.
public protocol Store: Sendable {
    // MARK: Users
    func upsertUser(robloxUserID: Int64, username: String, displayName: String, now: Date) async throws -> UserRecord
    func user(id: UUID) async throws -> UserRecord?

    // MARK: OAuth attempts
    func saveOAuthAttempt(_ attempt: OAuthAttempt) async throws
    /// Atomically removes and returns the attempt. A second call with the same state returns `nil`.
    func consumeOAuthAttempt(state: String) async throws -> OAuthAttempt?
    func deleteOAuthAttempts(createdBefore: Date) async throws

    // MARK: Roblox grants
    func saveGrant(_ grant: RobloxGrant) async throws
    func grant(userID: UUID) async throws -> RobloxGrant?
    /// Atomically replaces the grant only if its refresh-token hash still equals `expectedRefreshTokenHash`.
    /// Returns `false` when another writer rotated it first.
    func replaceGrant(_ grant: RobloxGrant, expectedRefreshTokenHash: String) async throws -> Bool
    func deleteGrant(userID: UUID) async throws
    func allGrants() async throws -> [RobloxGrant]

    // MARK: One-time session codes
    func saveSessionCode(hash: String, userID: UUID, expiresAt: Date) async throws
    /// Atomically removes the code and returns its user if it hadn't expired.
    func consumeSessionCode(hash: String, now: Date) async throws -> UUID?

    // MARK: Sessions
    func insertSession(_ session: SessionRecord) async throws
    func session(accessTokenHash: String) async throws -> SessionRecord?
    func session(refreshTokenHash: String) async throws -> SessionRecord?
    /// Atomically marks `oldSessionID` rotated and inserts `newSession`, only if the old session is still
    /// active. Returns `false` (and inserts nothing) if it was already rotated or revoked.
    func rotateSession(oldSessionID: UUID, newSession: SessionRecord, now: Date) async throws -> Bool
    func revokeSessionFamily(familyID: UUID, now: Date) async throws
    func revokeSessions(userID: UUID, now: Date) async throws

    // MARK: Games and metrics
    func upsertGameInfo(_ infos: [GameInfo]) async throws
    func gameInfo(universeIDs: [Int64]) async throws -> [Int64: GameInfo]
    func flags(userID: UUID) async throws -> [Int64: GameFlags]
    func setFavourite(userID: UUID, universeID: Int64, value: Bool) async throws
    func setWorkingOn(userID: UUID, universeID: Int64, value: Bool) async throws
    func appendSamples(_ samples: [MetricSample]) async throws
    /// Samples in `[from, to]`, oldest first.
    func samples(universeID: Int64, metric: Metric, from: Date, to: Date) async throws -> [MetricPoint]
    /// Most recent sample at or before `atOrBefore` for each universe that has one.
    func latestSample(universeIDs: [Int64], metric: Metric, atOrBefore: Date) async throws -> [Int64: MetricPoint]
    func deleteSamples(before: Date) async throws

    // MARK: Goals
    func goals(userID: UUID) async throws -> [Goal]
    func saveGoal(userID: UUID, goal: Goal) async throws

    // MARK: Alerts
    func alertRules(userID: UUID) async throws -> [AlertRule]
    func enabledAlertRules() async throws -> [OwnedAlertRule]
    /// Owner of a rule ID regardless of enabled state; `nil` if no such rule exists.
    func alertRuleOwner(ruleID: UUID) async throws -> UUID?
    /// Inserts or updates. Never transfers an existing rule to a different user (no-op instead).
    func saveAlertRule(userID: UUID, rule: AlertRule) async throws
    /// Returns `false` if no such rule belongs to the user.
    func deleteAlertRule(userID: UUID, ruleID: UUID) async throws -> Bool
    func alertState(ruleID: UUID) async throws -> AlertRuleState
    func saveAlertState(ruleID: UUID, state: AlertRuleState) async throws
    func appendAlertEvent(userID: UUID, event: AlertEvent) async throws
    func recentAlertEvents(userID: UUID, limit: Int) async throws -> [AlertEvent]

    // MARK: Devices
    func saveDevice(_ device: DeviceRecord) async throws
    func devices(userID: UUID) async throws -> [DeviceRecord]
    func deleteDevice(token: String) async throws

    // MARK: Timeline (updates, campaign changes, incidents) for possible causes and update reports
    /// Inserts events, ignoring ones already stored (same game, kind and time).
    func appendTimelineEvents(_ events: [TimelineEvent]) async throws
    /// Events for these games plus platform-wide ones (`gameID == nil`) overlapping `[from, to]`, oldest first.
    func timelineEvents(universeIDs: [Int64], from: Date, to: Date) async throws -> [TimelineEvent]

    // MARK: Analytics (daily metrics and funnels)
    /// Inserts or replaces (same universe, metric and time): Roblox revises recent days.
    func upsertInsightSamples(_ samples: [InsightSample]) async throws
    /// Values in `[from, to]`, oldest first.
    func insightSamples(universeID: Int64, metric: InsightMetric, from: Date, to: Date) async throws -> [InsightSample]
    /// Inserts or replaces (same universe, funnel and period end).
    func saveFunnelSnapshots(_ snapshots: [FunnelSnapshot]) async throws
    /// The newest snapshot of each funnel for the universe.
    func latestFunnelSnapshots(universeID: Int64) async throws -> [FunnelSnapshot]

    // MARK: Imported ad campaigns (Ads Manager CSV)
    /// Inserts or replaces by campaign ID for this user.
    func saveImportedCampaigns(userID: UUID, campaigns: [Campaign], now: Date) async throws
    func importedCampaigns(userID: UUID) async throws -> [Campaign]

    // MARK: Error reports from the game (decision 0008)
    /// Stores the key's hash for this user and universe, replacing the user's previous key for it.
    func saveIngestKey(hash: String, userID: UUID, universeID: Int64, createdAt: Date) async throws
    func ingestKey(hash: String) async throws -> IngestKeyRecord?
    /// Adds counts to the universe's rows for the UTC day starting at `day`. A signature not yet seen that day is
    /// dropped once the day has `ErrorReportLimits.signaturesPerDay` signatures.
    func addErrorCounts(universeID: Int64, day: Date, counts: [ErrorCount]) async throws
    /// Rows last seen at or after `since`, one per day, signature, place version and source.
    func errorCounts(universeID: Int64, since: Date) async throws -> [ErrorCount]
    func deleteErrorCounts(before: Date) async throws

    // MARK: Digest pushes
    /// Atomically records that `key` was pushed to the user at `at`, unless it was already pushed within
    /// `cooldown`. Returns `true` when the caller should push.
    func claimDigestPush(userID: UUID, key: String, at: Date, cooldown: TimeInterval) async throws -> Bool

    // MARK: AI
    func aiConsent(userID: UUID) async throws -> AIConsent?
    /// `nil` withdraws consent.
    func setAIConsent(userID: UUID, consent: AIConsent?) async throws
    func recordAIUsage(_ usage: AIUsageRecord) async throws
    /// Total cost of all AI calls at or after `since`, in micro-dollars.
    func aiCostMicros(since: Date) async throws -> Int64
    /// Number of the user's calls for `feature` at or after `since`.
    func aiRequestCount(userID: UUID, feature: String, since: Date) async throws -> Int

    // MARK: Account
    /// Removes everything belonging to the user (disconnect / account deletion).
    func deleteUser(id: UUID) async throws
}
