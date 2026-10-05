import RBXPulseKit
import SwiftUI
import WidgetKit

@main
struct RBXPulseApp: App {
    @State private var model: AppModel
    private let configuration: AppConfiguration

    init() {
        let configuration = AppConfiguration.current()
        self.configuration = configuration
        _model = State(initialValue: Self.makeModel(configuration: configuration))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(colorScheme)
                .onOpenURL { url in
                    model.handle(url: url)
                }
                .task {
                    if let url = configuration.launchURL { model.handle(url: url) }
                }
        }
    }

    private var colorScheme: ColorScheme? {
        switch configuration.forcedColorScheme {
        case .dark: .dark
        case .light: .light
        case nil: nil
        }
    }

    @MainActor
    private static func makeModel(configuration: AppConfiguration) -> AppModel {
        let service: any DashboardService
        switch configuration.dataSource {
        case .demo(let mode):
            service = DemoDashboardService(mode: mode)
        case .remote(let baseURL):
            let transport = URLSessionTransport()
            let refresher = BackendTokenRefresher(client: APIClient(baseURL: baseURL, transport: transport, auth: nil))
            let auth = AuthSessionCoordinator(store: KeychainTokenStore(), refresher: refresher)
            service = RemoteDashboardService(client: APIClient(baseURL: baseURL, transport: transport, auth: auth))
        }
        return AppModel(
            service: service,
            snapshotStore: SnapshotStore(appGroup: SharedConfiguration.appGroup),
            onSnapshotPublished: { WidgetCenter.shared.reloadAllTimelines() }
        )
    }
}
