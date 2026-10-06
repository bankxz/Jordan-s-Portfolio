import Foundation
import Logging
import NIOCore
import NIOSSL
import PostgresNIO
import PeakKit

/// Production store. Atomicity comes from single statements (`DELETE ... RETURNING`, guarded `UPDATE`)
/// or explicit transactions, matching the `Store` contract.
public struct PostgresStore: Store {
    private let client: PostgresClient
    private let logger: Logger

    public init(client: PostgresClient, logger: Logger) {
        self.client = client
        self.logger = logger
    }

    // MARK: Configuration

    /// Parses `postgres://user:password@host:port/database?sslmode=disable|prefer|require`.
    public static func configuration(url string: String) throws -> PostgresClient.Configuration {
        guard let components = URLComponents(string: string),
              ["postgres", "postgresql"].contains(components.scheme ?? ""),
              let host = components.host, host.isEmpty == false,
              let user = components.percentEncodedUser?.removingPercentEncoding else {
            throw ServerConfig.ConfigError.invalid("DATABASE_URL", reason: "expected postgres://user:password@host:port/database")
        }
        let database = components.path.split(separator: "/").first.map(String.init)
        let tls: PostgresClient.Configuration.TLS
        switch components.queryItems?.first(where: { $0.name == "sslmode" })?.value ?? "prefer" {
        case "disable": tls = .disable
        case "require", "verify-full": tls = .require(.makeClientConfiguration())
        default: tls = .prefer(.makeClientConfiguration())
        }
        return PostgresClient.Configuration(host: host, port: components.port ?? 5432, username: user,
                                            password: components.percentEncodedPassword?.removingPercentEncoding,
                                            database: database, tls: tls)
    }

    // MARK: Migrations

    /// Ordered, append-only. Never edit a shipped migration; add a new one.
    static let migrations: [(version: Int, statements: [String])] = [
        (1, [
            """
            CREATE TABLE users (
                id UUID PRIMARY KEY,
                roblox_user_id BIGINT NOT NULL UNIQUE,
                username TEXT NOT NULL,
                display_name TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL)
            """,
            "CREATE TABLE oauth_attempts (state TEXT PRIMARY KEY, code_verifier TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL)",
            """
            CREATE TABLE roblox_grants (
                user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
                access_token_sealed BYTEA NOT NULL,
                refresh_token_sealed BYTEA NOT NULL,
                refresh_token_hash TEXT NOT NULL,
                access_token_expires_at TIMESTAMPTZ NOT NULL,
                scopes TEXT[] NOT NULL,
                universe_ids BIGINT[] NOT NULL,
                updated_at TIMESTAMPTZ NOT NULL)
            """,
            """
            CREATE TABLE session_codes (
                code_hash TEXT PRIMARY KEY,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                expires_at TIMESTAMPTZ NOT NULL)
            """,
            """
            CREATE TABLE sessions (
                id UUID PRIMARY KEY,
                family_id UUID NOT NULL,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                access_token_hash TEXT NOT NULL UNIQUE,
                access_expires_at TIMESTAMPTZ NOT NULL,
                refresh_token_hash TEXT NOT NULL UNIQUE,
                refresh_expires_at TIMESTAMPTZ NOT NULL,
                created_at TIMESTAMPTZ NOT NULL,
                rotated_at TIMESTAMPTZ,
                revoked_at TIMESTAMPTZ)
            """,
            "CREATE INDEX sessions_family_idx ON sessions (family_id)",
            "CREATE INDEX sessions_user_idx ON sessions (user_id)",
            """
            CREATE TABLE game_info (
                universe_id BIGINT PRIMARY KEY,
                root_place_id BIGINT NOT NULL,
                name TEXT NOT NULL,
                updated_at TIMESTAMPTZ NOT NULL)
            """,
            """
            CREATE TABLE game_flags (
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                universe_id BIGINT NOT NULL,
                is_favourite BOOLEAN NOT NULL DEFAULT FALSE,
                is_working_on BOOLEAN NOT NULL DEFAULT FALSE,
                PRIMARY KEY (user_id, universe_id))
            """,
            """
            CREATE TABLE metric_samples (
                universe_id BIGINT NOT NULL,
                metric TEXT NOT NULL,
                time TIMESTAMPTZ NOT NULL,
                value DOUBLE PRECISION NOT NULL,
                PRIMARY KEY (universe_id, metric, time))
            """,
            "CREATE INDEX metric_samples_time_idx ON metric_samples (time)",
            """
            CREATE TABLE goals (
                id UUID PRIMARY KEY,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                body TEXT NOT NULL)
            """,
            """
            CREATE TABLE alert_rules (
                id UUID PRIMARY KEY,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                is_enabled BOOLEAN NOT NULL,
                body TEXT NOT NULL)
            """,
            """
            CREATE TABLE alert_states (
                rule_id UUID PRIMARY KEY REFERENCES alert_rules(id) ON DELETE CASCADE,
                condition_was_met BOOLEAN NOT NULL,
                last_fired_at TIMESTAMPTZ)
            """,
            """
            CREATE TABLE alert_events (
                id BIGSERIAL PRIMARY KEY,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                fired_at TIMESTAMPTZ NOT NULL,
                body TEXT NOT NULL)
            """,
            "CREATE INDEX alert_events_user_idx ON alert_events (user_id, fired_at DESC)",
            """
            CREATE TABLE devices (
                token TEXT PRIMARY KEY,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                sandbox BOOLEAN NOT NULL,
                updated_at TIMESTAMPTZ NOT NULL)
            """,
        ]),
        (2, [
            // universe_id 0 = platform-wide event (Roblox incident, calendar).
            """
            CREATE TABLE timeline_events (
                universe_id BIGINT NOT NULL,
                kind TEXT NOT NULL,
                time TIMESTAMPTZ NOT NULL,
                end_time TIMESTAMPTZ,
                detail TEXT NOT NULL,
                PRIMARY KEY (universe_id, kind, time))
            """,
            "CREATE INDEX timeline_events_time_idx ON timeline_events (time)",
            """
            CREATE TABLE ai_consents (
                user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
                consented_at TIMESTAMPTZ NOT NULL)
            """,
            """
            CREATE TABLE ai_usage (
                id BIGSERIAL PRIMARY KEY,
                user_id UUID REFERENCES users(id) ON DELETE SET NULL,
                feature TEXT NOT NULL,
                model TEXT NOT NULL,
                input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                cost_micros BIGINT NOT NULL,
                time TIMESTAMPTZ NOT NULL)
            """,
            "CREATE INDEX ai_usage_time_idx ON ai_usage (time)",
            "CREATE INDEX ai_usage_user_idx ON ai_usage (user_id, feature, time)",
        ]),
    ]

    /// Applies pending migrations under an advisory lock, so several instances starting at once are safe.
    public func migrate() async throws {
        try await client.withConnection { connection in
            try await connection.query("SELECT pg_advisory_lock(72_617_301)", logger: logger)
            do {
                try await connection.query("""
                    CREATE TABLE IF NOT EXISTS schema_migrations (
                        version INTEGER PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())
                    """, logger: logger)
                var applied = Set<Int>()
                for try await version in try await connection.query("SELECT version FROM schema_migrations", logger: logger)
                    .decode(Int.self) {
                    applied.insert(version)
                }
                for migration in Self.migrations where applied.contains(migration.version) == false {
                    try await connection.withTransaction(logger: logger) { tx in
                        for statement in migration.statements {
                            try await tx.query(PostgresQuery(unsafeSQL: statement), logger: logger)
                        }
                        try await tx.query("INSERT INTO schema_migrations (version) VALUES (\(migration.version))", logger: logger)
                    }
                    logger.info("applied migration", metadata: ["version": "\(migration.version)"])
                }
            } catch {
                _ = try? await connection.query("SELECT pg_advisory_unlock(72_617_301)", logger: logger)
                throw error
            }
            try await connection.query("SELECT pg_advisory_unlock(72_617_301)", logger: logger)
        }
    }

    // MARK: Users

    public func upsertUser(robloxUserID: Int64, username: String, displayName: String, now: Date) async throws -> UserRecord {
        let rows = try await client.query("""
            INSERT INTO users (id, roblox_user_id, username, display_name, created_at)
            VALUES (\(UUID()), \(robloxUserID), \(username), \(displayName), \(now))
            ON CONFLICT (roblox_user_id) DO UPDATE SET username = EXCLUDED.username, display_name = EXCLUDED.display_name
            RETURNING id, roblox_user_id, username, display_name, created_at
            """, logger: logger)
        for try await (id, robloxID, name, display, created) in rows.decode((UUID, Int64, String, String, Date).self) {
            return UserRecord(id: id, robloxUserID: robloxID, username: name, displayName: display, createdAt: created)
        }
        throw PostgresStoreError.missingRow
    }

    public func user(id: UUID) async throws -> UserRecord? {
        let rows = try await client.query(
            "SELECT id, roblox_user_id, username, display_name, created_at FROM users WHERE id = \(id)", logger: logger)
        for try await (id, robloxID, name, display, created) in rows.decode((UUID, Int64, String, String, Date).self) {
            return UserRecord(id: id, robloxUserID: robloxID, username: name, displayName: display, createdAt: created)
        }
        return nil
    }

    // MARK: OAuth attempts

    public func saveOAuthAttempt(_ attempt: OAuthAttempt) async throws {
        try await client.query("""
            INSERT INTO oauth_attempts (state, code_verifier, created_at)
            VALUES (\(attempt.state), \(attempt.codeVerifier), \(attempt.createdAt))
            """, logger: logger)
    }

    public func consumeOAuthAttempt(state: String) async throws -> OAuthAttempt? {
        let rows = try await client.query(
            "DELETE FROM oauth_attempts WHERE state = \(state) RETURNING state, code_verifier, created_at", logger: logger)
        for try await (state, verifier, created) in rows.decode((String, String, Date).self) {
            return OAuthAttempt(state: state, codeVerifier: verifier, createdAt: created)
        }
        return nil
    }

    public func deleteOAuthAttempts(createdBefore: Date) async throws {
        try await client.query("DELETE FROM oauth_attempts WHERE created_at < \(createdBefore)", logger: logger)
    }

    // MARK: Grants

    private static let grantColumns = """
        user_id, access_token_sealed, refresh_token_sealed, refresh_token_hash, access_token_expires_at,
        scopes, universe_ids, updated_at
        """

    private func grants(_ query: PostgresQuery) async throws -> [RobloxGrant] {
        var result: [RobloxGrant] = []
        let rows = try await client.query(query, logger: logger)
        for try await (user, access, refresh, hash, expires, scopes, universes, updated)
            in rows.decode((UUID, ByteBuffer, ByteBuffer, String, Date, [String], [Int64], Date).self) {
            result.append(RobloxGrant(userID: user, accessTokenSealed: Data(buffer: access), refreshTokenSealed: Data(buffer: refresh),
                                      refreshTokenHash: hash, accessTokenExpiresAt: expires, scopes: scopes,
                                      universeIDs: universes, updatedAt: updated))
        }
        return result
    }

    public func saveGrant(_ grant: RobloxGrant) async throws {
        try await client.query("""
            INSERT INTO roblox_grants (\(unescaped: Self.grantColumns))
            VALUES (\(grant.userID), \(ByteBuffer(bytes: grant.accessTokenSealed)), \(ByteBuffer(bytes: grant.refreshTokenSealed)),
                    \(grant.refreshTokenHash), \(grant.accessTokenExpiresAt), \(grant.scopes), \(grant.universeIDs), \(grant.updatedAt))
            ON CONFLICT (user_id) DO UPDATE SET
                access_token_sealed = EXCLUDED.access_token_sealed, refresh_token_sealed = EXCLUDED.refresh_token_sealed,
                refresh_token_hash = EXCLUDED.refresh_token_hash, access_token_expires_at = EXCLUDED.access_token_expires_at,
                scopes = EXCLUDED.scopes, universe_ids = EXCLUDED.universe_ids, updated_at = EXCLUDED.updated_at
            """, logger: logger)
    }

    public func grant(userID: UUID) async throws -> RobloxGrant? {
        try await grants("SELECT \(unescaped: Self.grantColumns) FROM roblox_grants WHERE user_id = \(userID)").first
    }

    public func replaceGrant(_ grant: RobloxGrant, expectedRefreshTokenHash: String) async throws -> Bool {
        let rows = try await client.query("""
            UPDATE roblox_grants SET
                access_token_sealed = \(ByteBuffer(bytes: grant.accessTokenSealed)),
                refresh_token_sealed = \(ByteBuffer(bytes: grant.refreshTokenSealed)),
                refresh_token_hash = \(grant.refreshTokenHash),
                access_token_expires_at = \(grant.accessTokenExpiresAt),
                scopes = \(grant.scopes), universe_ids = \(grant.universeIDs), updated_at = \(grant.updatedAt)
            WHERE user_id = \(grant.userID) AND refresh_token_hash = \(expectedRefreshTokenHash)
            RETURNING user_id
            """, logger: logger)
        return try await rows.decode(UUID.self).contains { _ in true }
    }

    public func deleteGrant(userID: UUID) async throws {
        try await client.query("DELETE FROM roblox_grants WHERE user_id = \(userID)", logger: logger)
    }

    public func allGrants() async throws -> [RobloxGrant] {
        try await grants("SELECT \(unescaped: Self.grantColumns) FROM roblox_grants")
    }

    // MARK: Session codes

    public func saveSessionCode(hash: String, userID: UUID, expiresAt: Date) async throws {
        try await client.query(
            "INSERT INTO session_codes (code_hash, user_id, expires_at) VALUES (\(hash), \(userID), \(expiresAt))", logger: logger)
    }

    public func consumeSessionCode(hash: String, now: Date) async throws -> UUID? {
        let rows = try await client.query(
            "DELETE FROM session_codes WHERE code_hash = \(hash) RETURNING user_id, expires_at", logger: logger)
        for try await (user, expires) in rows.decode((UUID, Date).self) {
            return expires > now ? user : nil
        }
        return nil
    }

    // MARK: Sessions

    private static let sessionColumns = """
        id, family_id, user_id, access_token_hash, access_expires_at, refresh_token_hash, refresh_expires_at,
        created_at, rotated_at, revoked_at
        """

    private func sessions(_ query: PostgresQuery, on connection: PostgresConnection? = nil) async throws -> [SessionRecord] {
        let rows = if let connection {
            try await connection.query(query, logger: logger)
        } else {
            try await client.query(query, logger: logger)
        }
        var result: [SessionRecord] = []
        for try await (id, family, user, accessHash, accessExp, refreshHash, refreshExp, created, rotated, revoked)
            in rows.decode((UUID, UUID, UUID, String, Date, String, Date, Date, Date?, Date?).self) {
            result.append(SessionRecord(id: id, familyID: family, userID: user, accessTokenHash: accessHash,
                                        accessExpiresAt: accessExp, refreshTokenHash: refreshHash, refreshExpiresAt: refreshExp,
                                        createdAt: created, rotatedAt: rotated, revokedAt: revoked))
        }
        return result
    }

    private static func insertSessionQuery(_ s: SessionRecord) -> PostgresQuery {
        """
        INSERT INTO sessions (\(unescaped: sessionColumns))
        VALUES (\(s.id), \(s.familyID), \(s.userID), \(s.accessTokenHash), \(s.accessExpiresAt), \(s.refreshTokenHash),
                \(s.refreshExpiresAt), \(s.createdAt), \(s.rotatedAt), \(s.revokedAt))
        """
    }

    public func insertSession(_ session: SessionRecord) async throws {
        try await client.query(Self.insertSessionQuery(session), logger: logger)
    }

    public func session(accessTokenHash: String) async throws -> SessionRecord? {
        try await sessions("SELECT \(unescaped: Self.sessionColumns) FROM sessions WHERE access_token_hash = \(accessTokenHash)").first
    }

    public func session(refreshTokenHash: String) async throws -> SessionRecord? {
        try await sessions("SELECT \(unescaped: Self.sessionColumns) FROM sessions WHERE refresh_token_hash = \(refreshTokenHash)").first
    }

    public func rotateSession(oldSessionID: UUID, newSession: SessionRecord, now: Date) async throws -> Bool {
        let logger = self.logger
        return try await client.withTransaction(logger: logger) { tx in
            let updated = try await tx.query("""
                UPDATE sessions SET rotated_at = \(now)
                WHERE id = \(oldSessionID) AND rotated_at IS NULL AND revoked_at IS NULL
                RETURNING id
                """, logger: logger)
            guard try await updated.decode(UUID.self).contains(where: { _ in true }) else { return false }
            try await tx.query(Self.insertSessionQuery(newSession), logger: logger)
            return true
        }
    }

    public func revokeSessionFamily(familyID: UUID, now: Date) async throws {
        try await client.query(
            "UPDATE sessions SET revoked_at = \(now) WHERE family_id = \(familyID) AND revoked_at IS NULL", logger: logger)
    }

    public func revokeSessions(userID: UUID, now: Date) async throws {
        try await client.query(
            "UPDATE sessions SET revoked_at = \(now) WHERE user_id = \(userID) AND revoked_at IS NULL", logger: logger)
    }

    // MARK: Games and metrics

    public func upsertGameInfo(_ infos: [GameInfo]) async throws {
        guard infos.isEmpty == false else { return }
        try await client.query("""
            INSERT INTO game_info (universe_id, root_place_id, name, updated_at)
            SELECT * FROM UNNEST(\(infos.map(\.universeID))::BIGINT[], \(infos.map(\.rootPlaceID))::BIGINT[],
                                 \(infos.map(\.name))::TEXT[], \(infos.map(\.updatedAt))::TIMESTAMPTZ[])
            ON CONFLICT (universe_id) DO UPDATE SET
                root_place_id = EXCLUDED.root_place_id, name = EXCLUDED.name, updated_at = EXCLUDED.updated_at
            """, logger: logger)
    }

    public func gameInfo(universeIDs: [Int64]) async throws -> [Int64: GameInfo] {
        guard universeIDs.isEmpty == false else { return [:] }
        let rows = try await client.query(
            "SELECT universe_id, root_place_id, name, updated_at FROM game_info WHERE universe_id = ANY(\(universeIDs))",
            logger: logger)
        var result: [Int64: GameInfo] = [:]
        for try await (id, place, name, updated) in rows.decode((Int64, Int64, String, Date).self) {
            result[id] = GameInfo(universeID: id, rootPlaceID: place, name: name, updatedAt: updated)
        }
        return result
    }

    public func flags(userID: UUID) async throws -> [Int64: GameFlags] {
        let rows = try await client.query(
            "SELECT universe_id, is_favourite, is_working_on FROM game_flags WHERE user_id = \(userID)", logger: logger)
        var result: [Int64: GameFlags] = [:]
        for try await (id, favourite, workingOn) in rows.decode((Int64, Bool, Bool).self) {
            result[id] = GameFlags(isFavourite: favourite, isWorkingOn: workingOn)
        }
        return result
    }

    public func setFavourite(userID: UUID, universeID: Int64, value: Bool) async throws {
        try await client.query("""
            INSERT INTO game_flags (user_id, universe_id, is_favourite) VALUES (\(userID), \(universeID), \(value))
            ON CONFLICT (user_id, universe_id) DO UPDATE SET is_favourite = EXCLUDED.is_favourite
            """, logger: logger)
    }

    public func setWorkingOn(userID: UUID, universeID: Int64, value: Bool) async throws {
        try await client.query("""
            INSERT INTO game_flags (user_id, universe_id, is_working_on) VALUES (\(userID), \(universeID), \(value))
            ON CONFLICT (user_id, universe_id) DO UPDATE SET is_working_on = EXCLUDED.is_working_on
            """, logger: logger)
    }

    public func appendSamples(_ samples: [MetricSample]) async throws {
        guard samples.isEmpty == false else { return }
        // Collapse duplicates within one batch: Postgres rejects ON CONFLICT hitting the same row twice.
        var unique: [String: MetricSample] = [:]
        for sample in samples { unique["\(sample.universeID)|\(sample.metric.rawValue)|\(sample.time.timeIntervalSince1970)"] = sample }
        let rows = Array(unique.values)
        try await client.query("""
            INSERT INTO metric_samples (universe_id, metric, time, value)
            SELECT * FROM UNNEST(\(rows.map(\.universeID))::BIGINT[], \(rows.map(\.metric.rawValue))::TEXT[],
                                 \(rows.map(\.time))::TIMESTAMPTZ[], \(rows.map(\.value))::DOUBLE PRECISION[])
            ON CONFLICT (universe_id, metric, time) DO UPDATE SET value = EXCLUDED.value
            """, logger: logger)
    }

    public func samples(universeID: Int64, metric: Metric, from: Date, to: Date) async throws -> [MetricPoint] {
        let rows = try await client.query("""
            SELECT time, value FROM metric_samples
            WHERE universe_id = \(universeID) AND metric = \(metric.rawValue) AND time >= \(from) AND time <= \(to)
            ORDER BY time
            """, logger: logger)
        var result: [MetricPoint] = []
        for try await (time, value) in rows.decode((Date, Double).self) {
            result.append(MetricPoint(date: time, value: value))
        }
        return result
    }

    public func latestSample(universeIDs: [Int64], metric: Metric, atOrBefore: Date) async throws -> [Int64: MetricPoint] {
        guard universeIDs.isEmpty == false else { return [:] }
        let rows = try await client.query("""
            SELECT DISTINCT ON (universe_id) universe_id, time, value FROM metric_samples
            WHERE universe_id = ANY(\(universeIDs)) AND metric = \(metric.rawValue) AND time <= \(atOrBefore)
            ORDER BY universe_id, time DESC
            """, logger: logger)
        var result: [Int64: MetricPoint] = [:]
        for try await (id, time, value) in rows.decode((Int64, Date, Double).self) {
            result[id] = MetricPoint(date: time, value: value)
        }
        return result
    }

    public func deleteSamples(before: Date) async throws {
        try await client.query("DELETE FROM metric_samples WHERE time < \(before)", logger: logger)
    }

    // MARK: Goals (stored as the app's JSON model)

    public func goals(userID: UUID) async throws -> [Goal] {
        let rows = try await client.query("SELECT body FROM goals WHERE user_id = \(userID) ORDER BY id", logger: logger)
        var result: [Goal] = []
        for try await body in rows.decode(String.self) { result.append(try Self.decode(Goal.self, body)) }
        return result
    }

    public func saveGoal(userID: UUID, goal: Goal) async throws {
        try await client.query("""
            INSERT INTO goals (id, user_id, body) VALUES (\(goal.id), \(userID), \(try Self.encode(goal)))
            ON CONFLICT (id) DO UPDATE SET body = EXCLUDED.body WHERE goals.user_id = EXCLUDED.user_id
            """, logger: logger)
    }

    // MARK: Alerts

    public func alertRules(userID: UUID) async throws -> [AlertRule] {
        let rows = try await client.query("SELECT body FROM alert_rules WHERE user_id = \(userID) ORDER BY id::text", logger: logger)
        var result: [AlertRule] = []
        for try await body in rows.decode(String.self) { result.append(try Self.decode(AlertRule.self, body)) }
        return result
    }

    public func enabledAlertRules() async throws -> [OwnedAlertRule] {
        let rows = try await client.query("SELECT user_id, body FROM alert_rules WHERE is_enabled ORDER BY id::text", logger: logger)
        var result: [OwnedAlertRule] = []
        for try await (user, body) in rows.decode((UUID, String).self) {
            result.append(OwnedAlertRule(userID: user, rule: try Self.decode(AlertRule.self, body)))
        }
        return result
    }

    public func alertRuleOwner(ruleID: UUID) async throws -> UUID? {
        let rows = try await client.query("SELECT user_id FROM alert_rules WHERE id = \(ruleID)", logger: logger)
        for try await user in rows.decode(UUID.self) { return user }
        return nil
    }

    public func saveAlertRule(userID: UUID, rule: AlertRule) async throws {
        try await client.query("""
            INSERT INTO alert_rules (id, user_id, is_enabled, body) VALUES (\(rule.id), \(userID), \(rule.isEnabled), \(try Self.encode(rule)))
            ON CONFLICT (id) DO UPDATE SET is_enabled = EXCLUDED.is_enabled, body = EXCLUDED.body
            WHERE alert_rules.user_id = EXCLUDED.user_id
            """, logger: logger)
    }

    public func deleteAlertRule(userID: UUID, ruleID: UUID) async throws -> Bool {
        let rows = try await client.query(
            "DELETE FROM alert_rules WHERE id = \(ruleID) AND user_id = \(userID) RETURNING id", logger: logger)
        return try await rows.decode(UUID.self).contains { _ in true }
    }

    public func alertState(ruleID: UUID) async throws -> AlertRuleState {
        let rows = try await client.query(
            "SELECT condition_was_met, last_fired_at FROM alert_states WHERE rule_id = \(ruleID)", logger: logger)
        for try await (met, fired) in rows.decode((Bool, Date?).self) {
            return AlertRuleState(conditionWasMet: met, lastFiredAt: fired)
        }
        return AlertRuleState()
    }

    public func saveAlertState(ruleID: UUID, state: AlertRuleState) async throws {
        try await client.query("""
            INSERT INTO alert_states (rule_id, condition_was_met, last_fired_at)
            VALUES (\(ruleID), \(state.conditionWasMet), \(state.lastFiredAt))
            ON CONFLICT (rule_id) DO UPDATE SET condition_was_met = EXCLUDED.condition_was_met,
                                                last_fired_at = EXCLUDED.last_fired_at
            """, logger: logger)
    }

    public func appendAlertEvent(userID: UUID, event: AlertEvent) async throws {
        try await client.query(
            "INSERT INTO alert_events (user_id, fired_at, body) VALUES (\(userID), \(event.firedAt), \(try Self.encode(event)))",
            logger: logger)
    }

    public func recentAlertEvents(userID: UUID, limit: Int) async throws -> [AlertEvent] {
        let rows = try await client.query("""
            SELECT body FROM alert_events WHERE user_id = \(userID) ORDER BY fired_at DESC, id DESC LIMIT \(max(0, limit))
            """, logger: logger)
        var result: [AlertEvent] = []
        for try await body in rows.decode(String.self) { result.append(try Self.decode(AlertEvent.self, body)) }
        return result
    }

    // MARK: Devices

    public func saveDevice(_ device: DeviceRecord) async throws {
        try await client.query("""
            INSERT INTO devices (token, user_id, sandbox, updated_at) VALUES (\(device.token), \(device.userID), \(device.sandbox), \(device.updatedAt))
            ON CONFLICT (token) DO UPDATE SET user_id = EXCLUDED.user_id, sandbox = EXCLUDED.sandbox, updated_at = EXCLUDED.updated_at
            """, logger: logger)
    }

    public func devices(userID: UUID) async throws -> [DeviceRecord] {
        let rows = try await client.query(
            "SELECT token, user_id, sandbox, updated_at FROM devices WHERE user_id = \(userID) ORDER BY token", logger: logger)
        var result: [DeviceRecord] = []
        for try await (token, user, sandbox, updated) in rows.decode((String, UUID, Bool, Date).self) {
            result.append(DeviceRecord(userID: user, token: token, sandbox: sandbox, updatedAt: updated))
        }
        return result
    }

    public func deleteDevice(token: String) async throws {
        try await client.query("DELETE FROM devices WHERE token = \(token)", logger: logger)
    }

    // MARK: Account

    // MARK: Timeline

    public func appendTimelineEvents(_ events: [TimelineEvent]) async throws {
        // A handful per poll at most, so one statement each keeps optional end times simple.
        for event in events {
            try await client.query("""
                INSERT INTO timeline_events (universe_id, kind, time, end_time, detail)
                VALUES (\(event.gameID ?? 0), \(event.kind.rawValue), \(event.date), \(event.endDate), \(event.detail))
                ON CONFLICT (universe_id, kind, time) DO NOTHING
                """, logger: logger)
        }
    }

    public func timelineEvents(universeIDs: [Int64], from: Date, to: Date) async throws -> [TimelineEvent] {
        let ids = universeIDs + [0]
        let rows = try await client.query("""
            SELECT universe_id, kind, time, end_time, detail FROM timeline_events
            WHERE universe_id = ANY(\(ids)) AND COALESCE(end_time, time) >= \(from) AND time <= \(to)
            ORDER BY time, universe_id, kind
            """, logger: logger)
        var result: [TimelineEvent] = []
        for try await (universe, kind, time, end, detail) in rows.decode((Int64, String, Date, Date?, String).self) {
            guard let kind = TimelineEvent.Kind(rawValue: kind) else { continue }
            result.append(TimelineEvent(kind: kind, gameID: universe == 0 ? nil : universe, date: time, endDate: end, detail: detail))
        }
        return result
    }

    // MARK: AI

    public func aiConsent(userID: UUID) async throws -> Date? {
        let rows = try await client.query("SELECT consented_at FROM ai_consents WHERE user_id = \(userID)", logger: logger)
        for try await date in rows.decode(Date.self) { return date }
        return nil
    }

    public func setAIConsent(userID: UUID, consentedAt: Date?) async throws {
        if let consentedAt {
            try await client.query("""
                INSERT INTO ai_consents (user_id, consented_at) VALUES (\(userID), \(consentedAt))
                ON CONFLICT (user_id) DO UPDATE SET consented_at = EXCLUDED.consented_at
                """, logger: logger)
        } else {
            try await client.query("DELETE FROM ai_consents WHERE user_id = \(userID)", logger: logger)
        }
    }

    public func recordAIUsage(_ usage: AIUsageRecord) async throws {
        try await client.query("""
            INSERT INTO ai_usage (user_id, feature, model, input_tokens, output_tokens, cost_micros, time)
            VALUES (\(usage.userID), \(usage.feature), \(usage.model), \(usage.inputTokens), \(usage.outputTokens),
                    \(usage.costMicros), \(usage.time))
            """, logger: logger)
    }

    public func aiCostMicros(since: Date) async throws -> Int64 {
        let rows = try await client.query("SELECT COALESCE(SUM(cost_micros), 0)::BIGINT FROM ai_usage WHERE time >= \(since)",
                                          logger: logger)
        for try await total in rows.decode(Int64.self) { return total }
        return 0
    }

    public func aiRequestCount(userID: UUID, feature: String, since: Date) async throws -> Int {
        let rows = try await client.query("""
            SELECT COUNT(*)::BIGINT FROM ai_usage WHERE user_id = \(userID) AND feature = \(feature) AND time >= \(since)
            """, logger: logger)
        for try await count in rows.decode(Int64.self) { return Int(count) }
        return 0
    }

    public func deleteUser(id: UUID) async throws {
        // Every user-owned table cascades from users.
        try await client.query("DELETE FROM users WHERE id = \(id)", logger: logger)
    }

    // MARK: JSON columns

    enum PostgresStoreError: Error { case missingRow }

    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970  // full precision, unlike ISO 8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ body: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(T.self, from: Data(body.utf8))
    }
}
