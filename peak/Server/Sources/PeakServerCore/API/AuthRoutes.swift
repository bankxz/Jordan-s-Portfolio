import Foundation
import Hummingbird
import PeakKit

/// `docs/api/backend-contract.md` → Auth.
struct AuthRoutes {
    let auth: AuthService

    func addPublicRoutes(to router: Router<AppRequestContext>, limiter: RateLimiter) {
        let group = router.group().add(middleware: RateLimitMiddleware(limiter: limiter))

        group.post("v1/auth/roblox/start") { _, _ in
            let url = try await auth.startAuthorization()
            return try JSONBody.response(BackendAPI.AuthStart(authorizeURL: url))
        }

        // Roblox redirects the browser here. Always answers with a redirect into the app.
        group.get("oauth/roblox/callback") { request, _ in
            let query = request.uri.queryParameters
            let target = await auth.completeAuthorization(code: query["code"].map(String.init),
                                                          state: query["state"].map(String.init),
                                                          error: query["error"].map(String.init))
            var headers = HTTPFields()
            headers[.location] = target.absoluteString
            headers[.cacheControl] = "no-store"
            return Response(status: .found, headers: headers)
        }

        group.post("v1/auth/session") { request, context in
            let body = try await JSONBody.decode(BackendAPI.SessionCodeBody.self, from: request, context: context)
            do {
                return try JSONBody.response(try await auth.exchangeSessionCode(body.code))
            } catch is SessionError {
                throw APIFailure.unauthorized
            }
        }

        group.post("v1/auth/refresh") { request, context in
            let body = try await JSONBody.decode(BackendAPI.RefreshBody.self, from: request, context: context)
            do {
                return try JSONBody.response(try await auth.refresh(refreshToken: body.refreshToken))
            } catch is SessionError {
                throw APIFailure.unauthorized
            }
        }
    }

    func addAuthenticatedRoutes(to group: RouterGroup<AppRequestContext>) {
        group.post("v1/auth/logout") { _, context in
            try await auth.logout(try context.requireAuth())
            return JSONBody.noContent()
        }

        group.delete("v1/account") { _, context in
            try await auth.deleteAccount(userID: try context.requireAuth().userID)
            return JSONBody.noContent()
        }
    }
}
