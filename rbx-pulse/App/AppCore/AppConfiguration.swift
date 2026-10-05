import Foundation
import RBXPulseKit

/// Runtime configuration from Info.plist and launch arguments.
///
/// Launch arguments used by UI tests and visual QA:
/// - `-demoMode normal|empty|failing` forces sample data in the given state
/// - `-colorScheme dark|light` forces an appearance
/// - `-UIPreferredContentSizeCategoryName <category>` (UIKit) forces a Dynamic Type size
struct AppConfiguration: Sendable {
    enum DataSource: Sendable, Equatable {
        case demo(DemoDashboardService.Mode)
        case remote(URL)
    }

    enum ForcedColorScheme: String, Sendable {
        case light, dark
    }

    let dataSource: DataSource
    let forcedColorScheme: ForcedColorScheme?

    static func current(bundle: Bundle = .main, arguments: [String] = ProcessInfo.processInfo.arguments) -> AppConfiguration {
        let forcedScheme = value(after: "-colorScheme", in: arguments).flatMap(ForcedColorScheme.init(rawValue:))

        if let mode = value(after: "-demoMode", in: arguments) {
            return AppConfiguration(dataSource: .demo(demoMode(named: mode)), forcedColorScheme: forcedScheme)
        }
        if let raw = bundle.object(forInfoDictionaryKey: "RBXPulseAPIBaseURL") as? String,
           raw.isEmpty == false, let url = URL(string: raw), url.scheme == "https" {
            return AppConfiguration(dataSource: .remote(url), forcedColorScheme: forcedScheme)
        }
        return AppConfiguration(dataSource: .demo(.normal), forcedColorScheme: forcedScheme)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func demoMode(named name: String) -> DemoDashboardService.Mode {
        switch name {
        case "empty": .empty
        case "failing": .failing
        default: .normal
        }
    }
}
