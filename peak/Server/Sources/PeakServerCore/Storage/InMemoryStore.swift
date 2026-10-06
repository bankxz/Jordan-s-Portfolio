import Foundation
import PeakKit

/// Actor-isolated store for tests and local development. Every method runs to completion without
/// suspending, so each one is atomic — matching the guarantees `PostgresStore` gets from transactions.
public actor InMemoryStore: Store {
    private var users: [UUID: UserRecord] = [:]
    private var attempts: [String: OAuthAttempt] = [:]
    private var grants: [UUID: RobloxGrant] = [:]
    private var sessionCodes: [String: (userID: UUID, expiresAt: Date)] = [:]
    private var sessions: [UUID: SessionRecord] = [:]
    private var games: [Int64: GameInfo] = [:]
    private var userFlags: [UUID: [Int64: GameFlags]] = [:]
    private var samples: [Int64: [Metric: [MetricPoint]]] = [:]
    private var userGoals: [UUID: [Goal]] = [:]
    private var rules: [UUID: OwnedAlertRule] = [:]
    private var ruleStates: [UUID: AlertRuleState] = [:]
    private var events: [UUID: [AlertEvent]] = [:]
    private var deviceRecords: [String: DeviceRecord] = [:]

    public init() {}

    // MARK: Users

    public func upsertUser(robloxUserID: Int64, username: String, displayName: String, now: Date) -> UserRecord {
        if var existing = users.values.first(where: { $0.robloxUserID == robloxUserID }) {
            existing.username = username
            existing.displayName = displayName
            users[existing.id] = existing
            return existing
        }
        let user = UserRecord(id: UUID(), robloxUserID: robloxUserID, username: username,
                              displayName: displayName, createdAt: now)
        users[user.id] = user
        return user
    }

    public func user(id: UUID) -> UserRecord? { users[id] }

    // MARK: OAuth attempts

    public func saveOAuthAttempt(_ attempt: OAuthAttempt) { attempts[attempt.state] = attempt }

    public func consumeOAuthAttempt(state: String) -> OAuthAttempt? { attempts.removeValue(forKey: state) }

    public func deleteOAuthAttempts(createdBefore: Date) {
        attempts = attempts.filter { $0.value.createdAt >= createdBefore }
    }

    // MARK: Grants

    public func saveGrant(_ grant: RobloxGrant) { grants[grant.userID] = grant }

    public func grant(userID: UUID) -> RobloxGrant? { grants[userID] }

    public func replaceGrant(_ grant: RobloxGrant, expectedRefreshTokenHash: String) -> Bool {
        guard let current = grants[grant.userID], current.refreshTokenHash == expectedRefreshTokenHash else { return false }
        grants[grant.userID] = grant
        return true
    }

    public func deleteGrant(userID: UUID) { grants[userID] = nil }

    public func allGrants() -> [RobloxGrant] { Array(grants.values) }

    // MARK: Session codes

    public func saveSessionCode(hash: String, userID: UUID, expiresAt: Date) {
        sessionCodes[hash] = (userID, expiresAt)
    }

    public func consumeSessionCode(hash: String, now: Date) -> UUID? {
        guard let entry = sessionCodes.removeValue(forKey: hash), entry.expiresAt > now else { return nil }
        return entry.userID
    }

    // MARK: Sessions

    public func insertSession(_ session: SessionRecord) { sessions[session.id] = session }

    public func session(accessTokenHash: String) -> SessionRecord? {
        sessions.values.first { $0.accessTokenHash == accessTokenHash }
    }

    public func session(refreshTokenHash: String) -> SessionRecord? {
        sessions.values.first { $0.refreshTokenHash == refreshTokenHash }
    }

    public func rotateSession(oldSessionID: UUID, newSession: SessionRecord, now: Date) -> Bool {
        guard var old = sessions[oldSessionID], old.isActive else { return false }
        old.rotatedAt = now
        sessions[oldSessionID] = old
        sessions[newSession.id] = newSession
        return true
    }

    public func revokeSessionFamily(familyID: UUID, now: Date) {
        for (id, session) in sessions where session.familyID == familyID && session.revokedAt == nil {
            sessions[id]?.revokedAt = now
        }
    }

    public func revokeSessions(userID: UUID, now: Date) {
        for (id, session) in sessions where session.userID == userID && session.revokedAt == nil {
            sessions[id]?.revokedAt = now
        }
    }

    // MARK: Games and metrics

    public func upsertGameInfo(_ infos: [GameInfo]) {
        for info in infos { games[info.universeID] = info }
    }

    public func gameInfo(universeIDs: [Int64]) -> [Int64: GameInfo] {
        Dictionary(uniqueKeysWithValues: universeIDs.compactMap { id in games[id].map { (id, $0) } })
    }

    public func flags(userID: UUID) -> [Int64: GameFlags] { userFlags[userID] ?? [:] }

    public func setFavourite(userID: UUID, universeID: Int64, value: Bool) {
        userFlags[userID, default: [:]][universeID, default: GameFlags()].isFavourite = value
    }

    public func setWorkingOn(userID: UUID, universeID: Int64, value: Bool) {
        userFlags[userID, default: [:]][universeID, default: GameFlags()].isWorkingOn = value
    }

    public func appendSamples(_ newSamples: [MetricSample]) {
        for sample in newSamples {
            var points = samples[sample.universeID, default: [:]][sample.metric, default: []]
            // Same timestamp → replace, so retried polls are idempotent.
            points.removeAll { $0.date == sample.time }
            points.append(MetricPoint(date: sample.time, value: sample.value))
            points.sort { $0.date < $1.date }
            samples[sample.universeID, default: [:]][sample.metric] = points
        }
    }

    public func samples(universeID: Int64, metric: Metric, from: Date, to: Date) -> [MetricPoint] {
        (samples[universeID]?[metric] ?? []).filter { $0.date >= from && $0.date <= to }
    }

    public func latestSample(universeIDs: [Int64], metric: Metric, atOrBefore: Date) -> [Int64: MetricPoint] {
        var result: [Int64: MetricPoint] = [:]
        for id in universeIDs {
            if let point = samples[id]?[metric]?.last(where: { $0.date <= atOrBefore }) {
                result[id] = point
            }
        }
        return result
    }

    public func deleteSamples(before: Date) {
        for (universe, byMetric) in samples {
            for (metric, points) in byMetric {
                samples[universe]?[metric] = points.filter { $0.date >= before }
            }
        }
    }

    // MARK: Goals

    public func goals(userID: UUID) -> [Goal] { userGoals[userID] ?? [] }

    public func saveGoal(userID: UUID, goal: Goal) {
        var list = userGoals[userID] ?? []
        list.removeAll { $0.id == goal.id }
        list.append(goal)
        userGoals[userID] = list
    }

    // MARK: Alerts

    public func alertRules(userID: UUID) -> [AlertRule] {
        rules.values.filter { $0.userID == userID }.map(\.rule).sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func enabledAlertRules() -> [OwnedAlertRule] {
        rules.values.filter(\.rule.isEnabled).sorted { $0.rule.id.uuidString < $1.rule.id.uuidString }
    }

    public func alertRuleOwner(ruleID: UUID) -> UUID? { rules[ruleID]?.userID }

    public func saveAlertRule(userID: UUID, rule: AlertRule) {
        // A rule never changes owner (same guarantee as the Postgres upsert).
        if let existing = rules[rule.id], existing.userID != userID { return }
        rules[rule.id] = OwnedAlertRule(userID: userID, rule: rule)
    }

    public func deleteAlertRule(userID: UUID, ruleID: UUID) -> Bool {
        guard rules[ruleID]?.userID == userID else { return false }
        rules[ruleID] = nil
        ruleStates[ruleID] = nil
        return true
    }

    public func alertState(ruleID: UUID) -> AlertRuleState { ruleStates[ruleID] ?? AlertRuleState() }

    public func saveAlertState(ruleID: UUID, state: AlertRuleState) { ruleStates[ruleID] = state }

    public func appendAlertEvent(userID: UUID, event: AlertEvent) { events[userID, default: []].append(event) }

    public func recentAlertEvents(userID: UUID, limit: Int) -> [AlertEvent] {
        Array((events[userID] ?? []).sorted { $0.firedAt > $1.firedAt }.prefix(max(0, limit)))
    }

    // MARK: Devices

    public func saveDevice(_ device: DeviceRecord) { deviceRecords[device.token] = device }

    public func devices(userID: UUID) -> [DeviceRecord] {
        deviceRecords.values.filter { $0.userID == userID }.sorted { $0.token < $1.token }
    }

    public func deleteDevice(token: String) { deviceRecords[token] = nil }

    // MARK: Account

    public func deleteUser(id: UUID) {
        users[id] = nil
        grants[id] = nil
        sessions = sessions.filter { $0.value.userID != id }
        sessionCodes = sessionCodes.filter { $0.value.userID != id }
        userFlags[id] = nil
        userGoals[id] = nil
        for (ruleID, owned) in rules where owned.userID == id {
            rules[ruleID] = nil
            ruleStates[ruleID] = nil
        }
        events[id] = nil
        deviceRecords = deviceRecords.filter { $0.value.userID != id }
    }
}
