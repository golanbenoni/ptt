import SwiftUI
import UIKit
import UserNotifications

extension Notification.Name {
    static let pttOpenEncryptedChat = Notification.Name("app.ptt.talk.open-encrypted-chat")
}

@MainActor
final class StandardPushCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = StandardPushCoordinator()
    private var tokenHandler: ((Data) -> Void)?
    private var wakeHandler: (() async -> Bool)?
    private var token: Data?

    func start(tokenHandler: @escaping (Data) -> Void, wakeHandler: @escaping () async -> Bool) {
        self.tokenHandler = tokenHandler
        self.wakeHandler = wakeHandler
        if let token { tokenHandler(token) }
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func received(token: Data) {
        self.token = token
        tokenHandler?(token)
    }

    func receivedWake() async -> Bool { await wakeHandler?() ?? false }

    func notifyEncryptedChat(count: Int, channelId: String, isMention: Bool = false) {
        guard count > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = isMention ? "New encrypted mention" :
            (count == 1 ? "New encrypted message" : "\(count) new encrypted messages")
        content.body = "Open PTT Talk to view the secure conversation."
        content.sound = .default
        // This identifier is added only to the local notification after the
        // encrypted mailbox has been opened. It is never sent to APNs.
        content.userInfo = ["channelId": channelId]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "ptt-encrypted-chat", content: content, trigger: nil)
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [.banner, .sound, .badge] }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            let channelId = response.notification.request.content.userInfo["channelId"] as? String
            NotificationCenter.default.post(name: .pttOpenEncryptedChat, object: channelId)
        }
    }
}

final class TalkAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ptt-e2e-") }) {
            // Physical release runs take several minutes. Keep an already
            // unlocked device awake so automation is not invalidated midway.
            application.isIdleTimerDisabled = true
        }
#endif
        UNUserNotificationCenter.current().delegate = StandardPushCoordinator.shared
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in StandardPushCoordinator.shared.received(token: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let receivedData = await StandardPushCoordinator.shared.receivedWake()
            completionHandler(receivedData ? .newData : .noData)
        }
    }
}

@main
struct TalkApp: App {
    @UIApplicationDelegateAdaptor(TalkAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            TalkView()
        }
    }
}
