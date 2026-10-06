import PeakKit
import SwiftUI
import WidgetKit

@main
struct PeakApp: App {
    @State private var model: AppModel
    @State private var insights: InsightsModel
    private let configuration: AppConfiguration

    init() {
        let configuration = AppConfiguration.current()
        self.configuration = configuration
        let models = Self.makeModels(configuration: configuration)
        _model = State(initialValue: models.app)
        _insights = State(initialValue: models.insights)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(insights)
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
    private static func makeModels(configuration: AppConfiguration) -> (app: AppModel, insights: InsightsModel) {
        let service: any DashboardService
        let insightService: any InsightService
        switch configuration.dataSource {
        case .demo(let mode):
            service = DemoDashboardService(mode: mode)
            insightService = DemoInsightService(mode: mode)
        case .remote(let baseURL):
            let transport = URLSessionTransport()
            let refresher = BackendTokenRefresher(client: APIClient(baseURL: baseURL, transport: transport, auth: nil))
            let auth = AuthSessionCoordinator(store: KeychainTokenStore(), refresher: refresher)
            let client = APIClient(baseURL: baseURL, transport: transport, auth: auth)
            service = RemoteDashboardService(client: client)
            insightService = RemoteInsightService(client: client)
        }
        let app = AppModel(
            service: service,
            snapshotStore: SnapshotStore(appGroup: SharedConfiguration.appGroup),
            onSnapshotPublished: { WidgetCenter.shared.reloadAllTimelines() }
        )
        return (app, InsightsModel(service: insightService))
    }
}
