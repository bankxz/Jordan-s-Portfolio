import Foundation
import Observation
import PeakKit
import UIKit
import UserNotifications

/// Notification permission, APNs registration and notification taps.
///
/// Permission is asked from a button with context (the Alerts tab), never at launch. Once granted, the device
/// token is sent to the backend with the time zone, so unusual-change digests arrive and the morning briefing
/// lands at 8:00 local time.
@MainActor
@Observable
final class NotificationController {
    enum Status: Equatable {
        case unknown
        case notDetermined
        case denied
        case enabled
    }

    private(set) var status: Status = .unknown
    private(set) var lastRegistrationError: String?

    @ObservationIgnored private var registration: (any PushRegistrationService)?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    /// A tap that arrived before the app finished configuring (cold start from a notification).
    @ObservationIgnored private var pendingURL: URL?

    func configure(model: AppModel, registration: any PushRegistrationService) {
        self.model = model
        self.registration = registration
        if let pendingURL {
            model.handle(url: pendingURL)
            self.pendingURL = nil
        }
    }

    /// Reads the current permission. When notifications are on, re-registers so a rotated token reaches the server.
    func refreshStatus() async {
        let authorization = await Self.authorizationStatus()
        switch authorization {
        case .authorized, .provisional, .ephemeral:
            status = .enabled
            UIApplication.shared.registerForRemoteNotifications()
        case .denied:
            status = .denied
        case .notDetermined:
            status = .notDetermined
        @unknown default:
            status = .unknown
        }
    }

    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshStatus()
    }

    /// Called by the app delegate with the APNs token. The previous upload, if still running, is replaced.
    @discardableResult
    func didRegister(token: Data) -> Task<Void, Never>? {
        guard let registration else { return nil }
        let zone = TimeZone.current.identifier
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        registrationTask?.cancel()
        registrationTask = Task { [weak self] in
            do {
                try await registration.register(apnsToken: token, sandbox: sandbox, timeZone: zone)
                self?.lastRegistrationError = nil
            } catch is CancellationError {
            } catch {
                self?.lastRegistrationError = "Couldn't turn on notifications with Peak's server. They'll be retried next launch."
            }
        }
        return registrationTask
    }

    func registrationFailed() {
        lastRegistrationError = "This device couldn't register for notifications."
    }

    /// A notification was tapped: open its Peak route (only Peak's own routes are followed).
    func open(userInfoURL url: URL?) {
        guard let url else { return }
        if let model {
            model.handle(url: url)
        } else {
            pendingURL = url
        }
    }

    /// `nonisolated` on purpose: the completion handler runs on a background queue. Inside this `@MainActor`
    /// class it would otherwise be main-actor isolated, and Swift 6's runtime check crashes the app when it's
    /// called off the main thread (the launch crash in CI run 37436023399).
    nonisolated private static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { @Sendable settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }
}

/// UIKit entry points SwiftUI doesn't offer: the APNs token and notification taps.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let notifications = NotificationController()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        notifications.didRegister(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        notifications.registrationFailed()
    }

    /// Show notifications while Peak is open too (they're about the creator's games, not chat messages).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let url = PushPayload.route(from: response.notification.request.content.userInfo)
        await MainActor.run {
            notifications.open(userInfoURL: url)
        }
    }
}
