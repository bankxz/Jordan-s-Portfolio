import Foundation
import RBXPulseServerCore

// Configuration errors are reported without echoing secret values.
do {
    let config = try ServerConfig.fromEnvironment()
    try await RBXPulseServerApp.run(config: config)
} catch let error as ServerConfig.ConfigError {
    print("rbxpulse-server: \(error.description)")
    exit(1)
}
