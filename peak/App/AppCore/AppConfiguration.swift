import Foundation
import PeakKit

/// Runtime configuration from Info.plist and launch arguments.
///
/// Launch arguments used by UI tests and visual QA:
/// - `-demoMode normal|empty|failing` forces sample data in the given state
/// - `-colorScheme dark|light` forces an appearance
/// - `-UIPreferredContentSizeCategoryName <category>` (UIKit) forces a Dynamic Type size
/// - `-openURL <url>` routes a deep link at launch (UI tests for widget/notification routing)
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
    var launchURL: URL?

    static func current(bundle: Bundle = .main, arguments: [String] = ProcessInfo.processInfo.arguments) -> AppConfiguration {
        let forcedScheme = value(after: "-colorScheme", in: arguments).flatMap(ForcedColorScheme.init(rawValue:))
        let launchURL = value(after: "-openURL", in: arguments).flatMap(URL.init(string:))
        var configuration = makeBase(bundle: bundle, arguments: arguments, forcedScheme: forcedScheme)
        configuration.launchURL = launchURL
        return configuration
    }

    private static func makeBase(bundle: Bundle, arguments: [String], forcedScheme: ForcedColorScheme?) -> AppConfiguration {
        if let mode = value(after: "-demoMode", in: arguments) {
            return AppConfiguration(dataSource: .demo(demoMode(named: mode)), forcedColorScheme: forcedScheme)
        }
        if let raw = bundle.object(forInfoDictionaryKey: "PeakAPIBaseURL") as? String,
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
