import PeakKit
import SwiftUI
import WidgetKit

@main
struct PeakApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var insights: InsightsModel
    @State private var account: AccountModel
    private let configuration: AppConfiguration

    init() {
        let configuration = AppConfiguration.current()
        self.configuration = configuration
        let models = Self.makeModels(configuration: configuration)
        _model = State(initialValue: models.app)
        _insights = State(initialValue: models.insights)
        _account = State(initialValue: models.account)
        registration = models.registration
    }

    private let registration: any PushRegistrationService

    var body: some Scene {
        WindowGroup {
            AppGate()
                .environment(model)
                .environment(insights)
                .environment(account)
                .environment(appDelegate.notifications)
                .preferredColorScheme(colorScheme)
                .onOpenURL { url in
                    model.handle(url: url)
                }
                .task {
                    appDelegate.notifications.configure(model: model, registration: registration)
                    await appDelegate.notifications.refreshStatus()
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
    private static func makeModels(configuration: AppConfiguration)
        -> (app: AppModel, insights: InsightsModel, account: AccountModel, registration: any PushRegistrationService) {
        let service: any DashboardService
        let insightService: any InsightService
        let registration: any PushRegistrationService
        let account: AccountModel
        switch configuration.dataSource {
        case .demo(let mode):
            service = DemoDashboardService(mode: mode)
            insightService = DemoInsightService(mode: mode)
            registration = DemoPushRegistration()
            account = AccountModel(service: DemoSignInService(signedIn: configuration.startsSignedOut == false),
                                   canSignOut: false)
        case .remote(let baseURL):
            let transport = URLSessionTransport()
            let refresher = BackendTokenRefresher(client: APIClient(baseURL: baseURL, transport: transport, auth: nil))
            let auth = AuthSessionCoordinator(store: KeychainTokenStore(), refresher: refresher)
            let client = APIClient(baseURL: baseURL, transport: transport, auth: auth)
            service = RemoteDashboardService(client: client)
            insightService = RemoteInsightService(client: client)
            registration = RemotePushRegistration(client: client)
            account = AccountModel(service: RemoteSignInService(client: client, session: auth), canSignOut: true)
        }
        let app = AppModel(
            service: service,
            snapshotStore: SnapshotStore(appGroup: SharedConfiguration.appGroup),
            onSnapshotPublished: { WidgetCenter.shared.reloadAllTimelines() }
        )
        return (app, InsightsModel(service: insightService), account, registration)
    }
}
