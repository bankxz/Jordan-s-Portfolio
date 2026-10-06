import Foundation
import PeakKit
import Testing
@testable import Peak

@MainActor
struct NotificationControllerTests {
    actor RecordingRegistration: PushRegistrationService {
        private(set) var calls: [(token: String, sandbox: Bool, zone: String)] = []
        var fail = false
        func setFail(_ value: Bool) { fail = value }
        func register(apnsToken: Data, sandbox: Bool, timeZone: String) async throws {
            calls.append((PushPayload.hex(apnsToken), sandbox, timeZone))
            if fail { throw URLError(.notConnectedToInternet) }
        }
    }

    func model() -> AppModel {
        AppModel(service: ScriptedService(), snapshotStore: nil, now: { Date(timeIntervalSince1970: 1_790_000_000) })
    }

    @Test func aTapBeforeLaunchFinishesIsRoutedOnceConfigured() {
        let controller = NotificationController()
        controller.open(userInfoURL: URL(string: "peakstats://game/920587237"))
        let app = model()
        controller.configure(model: app, registration: DemoPushRegistration())
        #expect(app.selectedTab == .games)
        #expect(app.gamesPath == [.game(id: 920_587_237)])
    }

    @Test func registrationSendsTheTokenAndTimeZone() async throws {
        let controller = NotificationController()
        let registration = RecordingRegistration()
        controller.configure(model: model(), registration: registration)
        await controller.didRegister(token: Data([0xab, 0x01]))?.value
        let call = try #require(await registration.calls.first)
        #expect(call.token == "ab01")
        #expect(call.zone == TimeZone.current.identifier)
        #expect(controller.lastRegistrationError == nil)

        await registration.setFail(true)
        await controller.didRegister(token: Data([0x02]))?.value
        #expect(controller.lastRegistrationError != nil)
    }

    @Test func withoutConfigurationNothingIsSent() {
        #expect(NotificationController().didRegister(token: Data([1])) == nil)
    }
}
