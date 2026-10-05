import Foundation
import Hummingbird

/// Builds and runs the HTTP application. Expanded as slices land.
public enum RBXPulseServerApp {
    public static func run(config: ServerConfig) async throws {
        let router = Router()
        router.get("health") { _, _ in "ok" }
        let app = Application(router: router, configuration: .init(address: .hostname(config.host, port: config.port)))
        try await app.runService()
    }
}
