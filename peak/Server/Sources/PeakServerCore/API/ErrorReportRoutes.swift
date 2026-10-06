import Foundation
import Hummingbird
import Logging
import PeakKit

/// Collects error reports in memory and writes them every few seconds (decision 0008). A game with hundreds of
/// servers, each reporting once a minute, then costs a handful of database writes instead of hundreds.
/// Best effort: a crash loses at most one flush interval of counts.
public actor ErrorIngestBuffer {
    private struct Key: Hashable {
        var universeID: Int64
        var day: Date
        var signature: String
        var placeVersion: Int?
        var source: String
    }

    private var pending: [Key: ErrorCount] = [:]
    private var lastPrune: Date?
    public static let maxPending = 20_000

    public init() {}

    /// Adds a validated report. Returns `true` when the buffer is full and should be flushed now.
    func add(universeID: Int64, report: BackendAPI.IngestErrors, at time: Date) -> Bool {
        let day = Calendar.utc.startOfDay(for: time)
        for entry in report.errors {
            let message = String(entry.message.prefix(BackendAPI.maxIngestMessageLength))
            let key = Key(universeID: universeID, day: day, signature: ErrorClusterer.signature(message),
                          placeVersion: report.placeVersion, source: entry.source ?? "server")
            if var existing = pending[key] {
                existing.count += entry.count
                existing.example = ErrorClusterer.redacted(message)
                existing.lastSeen = time
                pending[key] = existing
            } else if pending.count < Self.maxPending {
                pending[key] = ErrorCount(signature: key.signature, example: ErrorClusterer.redacted(message), source: key.source,
                                          placeVersion: key.placeVersion, count: entry.count, firstSeen: time, lastSeen: time)
            }
        }
        return pending.count >= Self.maxPending
    }

    /// Writes everything pending and, once an hour, deletes counts past retention. Returns the rows written.
    @discardableResult
    public func flush(into store: any Store, now: Date) async throws -> Int {
        let batch = pending
        pending = [:]
        for (target, rows) in Dictionary(grouping: batch, by: { BatchKey(universeID: $0.key.universeID, day: $0.key.day) }) {
            try await store.addErrorCounts(universeID: target.universeID, day: target.day, counts: rows.map(\.value))
        }
        if lastPrune.map({ now.timeIntervalSince($0) >= 3_600 }) ?? true {
            lastPrune = now
            try await store.deleteErrorCounts(before: Calendar.utc.startOfDay(for: now.addingTimeInterval(-ErrorReportLimits.retention)))
        }
        return batch.count
    }

    private struct BatchKey: Hashable {
        var universeID: Int64
        var day: Date
    }
}

/// `docs/api/backend-contract.md` → Error reports.
struct ErrorReportRoutes {
    let store: any Store
    let dashboard: DashboardBuilder
    let insights: InsightBuilder
    let buffer: ErrorIngestBuffer
    /// The server's public address, for the endpoint shown in the app. `nil` → key creation is unavailable.
    let publicBaseURL: URL?
    let limiter: RateLimiter
    let now: @Sendable () -> Date

    static let ingestBodyLimit = 128 * 1024

    func addAuthenticated(to group: RouterGroup<AppRequestContext>) {
        group.post("v1/games/:universeID/error-key") { _, context in
            let userID = try context.requireAuth().userID
            let universe = try InsightRoutes.universe(context)
            try await dashboard.requireOwnership(userID: userID, universeID: universe)
            guard let publicBaseURL else { throw APIFailure.unavailable("error_reports_unavailable") }
            let key = Secrets.randomToken(prefix: "pk_ik_")
            try await store.saveIngestKey(hash: Secrets.hash(key), userID: userID, universeID: universe, createdAt: now())
            return try JSONBody.response(BackendAPI.ErrorReportSetup(
                key: key, secretName: ErrorReporterScripts.secretName,
                endpoint: publicBaseURL.appendingPathComponent("v1/ingest/errors")))
        }

        group.get("v1/games/:universeID/errors") { _, context in
            let userID = try context.requireAuth().userID
            return try JSONBody.response(try await insights.errors(userID: userID, universe: try InsightRoutes.universe(context)))
        }
    }

    /// Called by the game's servers with the ingest key, not by the app: no session.
    func addPublic(to router: Router<AppRequestContext>) {
        router.post("v1/ingest/errors") { request, context in
            guard let header = request.headers[.authorization], header.hasPrefix("Bearer ") else {
                throw APIFailure.unauthorized
            }
            let key = String(header.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
            guard key.hasPrefix("pk_ik_"), key.count <= 100 else { throw APIFailure.unauthorized }
            let hash = Secrets.hash(key)
            guard let owner = try await store.ingestKey(hash: hash) else { throw APIFailure.unauthorized }
            if let retryAfter = await limiter.check(key: hash) { throw APIFailure.rateLimited(retryAfter: retryAfter) }
            // A key stops working when its owner loses access to the game.
            guard let grant = try await store.grant(userID: owner.userID), grant.universeIDs.contains(owner.universeID) else {
                throw APIFailure.unauthorized
            }

            let report = try await JSONBody.decode(BackendAPI.IngestErrors.self, from: request, context: context,
                                                   limit: Self.ingestBodyLimit)
            try Self.validate(report)
            let time = now()
            if await buffer.add(universeID: owner.universeID, report: report, at: time) {
                try await buffer.flush(into: store, now: time)
            }
            return Response(status: .accepted)
        }
    }

    /// Everything from a game is untrusted: player-controlled text reaches it through client errors.
    static func validate(_ report: BackendAPI.IngestErrors) throws {
        guard report.errors.count <= BackendAPI.maxIngestEntries else { throw APIFailure.badRequest("too_many_errors") }
        if let version = report.placeVersion, (0...Int(Int32.max)).contains(version) == false {
            throw APIFailure.badRequest("invalid_place_version")
        }
        for entry in report.errors {
            guard (1...ErrorReportLimits.maxEntryCount).contains(entry.count),
                  entry.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  entry.source == nil || entry.source == "server" || entry.source == "client" else {
                throw APIFailure.badRequest("invalid_error")
            }
        }
    }
}
