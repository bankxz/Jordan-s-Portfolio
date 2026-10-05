import Foundation
import RBXPulseKit

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

    // MARK: Account
    /// Removes everything belonging to the user (disconnect / account deletion).
    func deleteUser(id: UUID) async throws
}
