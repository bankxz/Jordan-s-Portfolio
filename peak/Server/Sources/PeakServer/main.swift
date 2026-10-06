import Foundation
import PeakServerCore

// Configuration errors are reported without echoing secret values.
do {
    let config = try ServerConfig.fromEnvironment()
    try await PeakServerApp.run(config: config)
} catch let error as ServerConfig.ConfigError {
    print("peak-server: \(error.description)")
    exit(1)
}
