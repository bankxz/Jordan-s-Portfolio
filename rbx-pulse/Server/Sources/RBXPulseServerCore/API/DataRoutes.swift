import Foundation
import Hummingbird
import RBXPulseKit

/// `docs/api/backend-contract.md` → Data, Devices, Alert rules. All routes require a session.
struct DataRoutes {
    let builder: DashboardBuilder
    let store: any Store
    let now: @Sendable () -> Date

    func add(to group: RouterGroup<AppRequestContext>) {
        group.get("v1/dashboard") { _, context in
            try JSONBody.response(try await builder.dashboard(userID: try context.requireAuth().userID))
        }

        group.get("v1/games/:universeID/series") { request, context in
            let userID = try context.requireAuth().userID
            let universe = try universeID(context)
            let query = request.uri.queryParameters
            guard let metric = query["metric"].flatMap({ Metric(rawValue: String($0)) }) else {
                throw APIFailure.badRequest("invalid_metric")
            }
            guard let range = query["range"].flatMap({ TimeRange(rawValue: String($0)) }) else {
                throw APIFailure.badRequest("invalid_range")
            }
            return try JSONBody.response(try await builder.series(userID: userID, universeID: universe, metric: metric, range: range))
        }

        group.put("v1/games/:universeID/favourite") { request, context in
            let userID = try context.requireAuth().userID
            let universe = try universeID(context)
            let body = try await JSONBody.decode(BackendAPI.FlagBody.self, from: request, context: context)
            try await builder.requireOwnership(userID: userID, universeID: universe)
            try await store.setFavourite(userID: userID, universeID: universe, value: body.value)
            return JSONBody.noContent()
        }

        group.put("v1/games/:universeID/working-on") { request, context in
            let userID = try context.requireAuth().userID
            let universe = try universeID(context)
            let body = try await JSONBody.decode(BackendAPI.FlagBody.self, from: request, context: context)
            try await builder.requireOwnership(userID: userID, universeID: universe)
            try await store.setWorkingOn(userID: userID, universeID: universe, value: body.value)
            return JSONBody.noContent()
        }

        group.post("v1/devices") { request, context in
            let userID = try context.requireAuth().userID
            let body = try await JSONBody.decode(BackendAPI.DeviceBody.self, from: request, context: context)
            let token = body.apnsToken.lowercased()
            guard (32...200).contains(token.count), token.allSatisfy(\.isHexDigit) else {
                throw APIFailure.badRequest("invalid_device_token")
            }
            try await store.saveDevice(DeviceRecord(userID: userID, token: token, sandbox: body.sandbox, updatedAt: now()))
            return JSONBody.noContent()
        }

        group.get("v1/alerts/rules") { _, context in
            try JSONBody.response(try await store.alertRules(userID: try context.requireAuth().userID))
        }

        group.put("v1/alerts/rules/:ruleID") { request, context in
            let userID = try context.requireAuth().userID
            let ruleID = try uuid(context, "ruleID")
            let rule = try await JSONBody.decode(AlertRule.self, from: request, context: context)
            guard rule.id == ruleID else { throw APIFailure.badRequest("id_mismatch") }
            try AlertRuleValidator.validate(rule)
            try await builder.requireOwnership(userID: userID, universeID: rule.gameID)
            switch try await store.alertRuleOwner(ruleID: rule.id) {
            case .some(let owner) where owner != userID:
                // Another user's rule ID: indistinguishable from "doesn't exist".
                throw APIFailure.notFound
            case .some:
                break  // updating own rule
            case .none:
                guard try await store.alertRules(userID: userID).count < AlertRuleValidator.maxRulesPerUser else {
                    throw APIFailure.badRequest("too_many_rules")
                }
            }
            try await store.saveAlertRule(userID: userID, rule: rule)
            return try JSONBody.response(rule)
        }

        group.delete("v1/alerts/rules/:ruleID") { _, context in
            let userID = try context.requireAuth().userID
            guard try await store.deleteAlertRule(userID: userID, ruleID: try uuid(context, "ruleID")) else {
                throw APIFailure.notFound
            }
            return JSONBody.noContent()
        }
    }

    private func universeID(_ context: AppRequestContext) throws -> Int64 {
        guard let raw = context.parameters.get("universeID"), raw.allSatisfy(\.isASCII),
              raw.allSatisfy(\.isNumber), let id = Int64(raw), id > 0 else {
            throw APIFailure.badRequest("invalid_universe")
        }
        return id
    }

    private func uuid(_ context: AppRequestContext, _ name: String) throws -> UUID {
        guard let raw = context.parameters.get(name), let id = UUID(uuidString: raw) else {
            throw APIFailure.badRequest("invalid_id")
        }
        return id
    }
}
