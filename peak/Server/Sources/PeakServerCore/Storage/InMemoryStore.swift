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
    private var timeline: [TimelineEvent] = []
    private var consents: [UUID: AIConsent] = [:]
    private var usage: [AIUsageRecord] = []
    private var insights: [InsightKey: Double] = [:]
    private var digestPushes: [String: Date] = [:]
    private var campaigns: [UUID: [String: Campaign]] = [:]
    private var funnels: [FunnelKey: FunnelSnapshot] = [:]
    private var ingestKeys: [String: (record: IngestKeyRecord, createdAt: Date)] = [:]
    private var errorRows: [ErrorKey: ErrorCount] = [:]

    private struct InsightKey: Hashable { var universeID: Int64; var metric: InsightMetric; var time: Date }
    private struct FunnelKey: Hashable { var universeID: Int64; var name: String; var periodEnd: Date }
    private struct ErrorKey: Hashable {
        var universeID: Int64; var day: Date; var signature: String; var placeVersion: Int?; var source: String
    }

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

    // MARK: Timeline

    public func appendTimelineEvents(_ newEvents: [TimelineEvent]) {
        for event in newEvents where timeline.contains(where: {
            $0.gameID == event.gameID && $0.kind == event.kind && $0.date == event.date
        }) == false {
            timeline.append(event)
        }
    }

    public func timelineEvents(universeIDs: [Int64], from: Date, to: Date) -> [TimelineEvent] {
        let wanted = Set(universeIDs)
        return timeline
            .filter { event in
                (event.gameID == nil || wanted.contains(event.gameID!))
                    && (event.endDate ?? event.date) >= from && event.date <= to
            }
            .sorted { $0.date < $1.date }
    }

    // MARK: Analytics

    public func upsertInsightSamples(_ samples: [InsightSample]) {
        for sample in samples where sample.value.isFinite {
            insights[InsightKey(universeID: sample.universeID, metric: sample.metric, time: sample.time)] = sample.value
        }
    }

    public func insightSamples(universeID: Int64, metric: InsightMetric, from: Date, to: Date) -> [InsightSample] {
        insights
            .filter { $0.key.universeID == universeID && $0.key.metric == metric && $0.key.time >= from && $0.key.time <= to }
            .map { InsightSample(universeID: universeID, metric: metric, time: $0.key.time, value: $0.value) }
            .sorted { $0.time < $1.time }
    }

    public func saveFunnelSnapshots(_ snapshots: [FunnelSnapshot]) {
        for snapshot in snapshots {
            funnels[FunnelKey(universeID: snapshot.universeID, name: snapshot.funnelName, periodEnd: snapshot.periodEnd)] = snapshot
        }
    }

    public func latestFunnelSnapshots(universeID: Int64) -> [FunnelSnapshot] {
        let mine = funnels.values.filter { $0.universeID == universeID }
        return Dictionary(grouping: mine, by: \.funnelName)
            .compactMap { $0.value.max { $0.periodEnd < $1.periodEnd } }
            .sorted { $0.funnelName < $1.funnelName }
    }

    // MARK: Imported campaigns

    public func saveImportedCampaigns(userID: UUID, campaigns new: [Campaign], now: Date) {
        for campaign in new { campaigns[userID, default: [:]][campaign.id] = campaign }
    }

    public func importedCampaigns(userID: UUID) -> [Campaign] {
        (campaigns[userID] ?? [:]).values.sorted { $0.name < $1.name }
    }

    // MARK: Error reports

    public func saveIngestKey(hash: String, userID: UUID, universeID: Int64, createdAt: Date) {
        ingestKeys = ingestKeys.filter { $0.value.record != IngestKeyRecord(userID: userID, universeID: universeID) }
        ingestKeys[hash] = (IngestKeyRecord(userID: userID, universeID: universeID), createdAt)
    }

    public func ingestKey(hash: String) -> IngestKeyRecord? { ingestKeys[hash]?.record }

    public func addErrorCounts(universeID: Int64, day: Date, counts: [ErrorCount]) {
        for count in counts {
            let key = ErrorKey(universeID: universeID, day: day, signature: count.signature,
                               placeVersion: count.placeVersion, source: count.source)
            if var row = errorRows[key] {
                row.count += count.count
                row.example = count.example
                row.firstSeen = min(row.firstSeen, count.firstSeen)
                row.lastSeen = max(row.lastSeen, count.lastSeen)
                errorRows[key] = row
                continue
            }
            let today = errorRows.keys.filter { $0.universeID == universeID && $0.day == day }
            guard today.contains(where: { $0.signature == count.signature })
                || Set(today.map(\.signature)).count < ErrorReportLimits.signaturesPerDay else { continue }
            errorRows[key] = count
        }
    }

    public func errorCounts(universeID: Int64, since: Date) -> [ErrorCount] {
        errorRows.filter { $0.key.universeID == universeID && $0.value.lastSeen >= since }.values
            .sorted { ($0.signature, $0.lastSeen) < ($1.signature, $1.lastSeen) }
    }

    public func deleteErrorCounts(before: Date) {
        errorRows = errorRows.filter { $0.key.day >= before }
    }

    // MARK: Digest pushes

    public func claimDigestPush(userID: UUID, key: String, at: Date, cooldown: TimeInterval) -> Bool {
        let id = "\(userID)|\(key)"
        if let last = digestPushes[id], at.timeIntervalSince(last) < cooldown { return false }
        digestPushes[id] = at
        return true
    }

    // MARK: AI

    public func aiConsent(userID: UUID) -> AIConsent? { consents[userID] }

    public func setAIConsent(userID: UUID, consent: AIConsent?) { consents[userID] = consent }

    public func recordAIUsage(_ record: AIUsageRecord) { usage.append(record) }

    public func aiCostMicros(since: Date) -> Int64 {
        usage.filter { $0.time >= since }.reduce(0) { $0 + $1.costMicros }
    }

    public func aiRequestCount(userID: UUID, feature: String, since: Date) -> Int {
        usage.filter { $0.userID == userID && $0.feature == feature && $0.time >= since }.count
    }

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
        consents[id] = nil
        campaigns[id] = nil
        ingestKeys = ingestKeys.filter { $0.value.record.userID != id }
        digestPushes = digestPushes.filter { $0.key.hasPrefix("\(id)|") == false }
        // Spend stays counted, without the link to the deleted user.
        usage = usage.map { record in
            var record = record
            if record.userID == id { record.userID = nil }
            return record
        }
    }
}
