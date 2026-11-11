import AgentCore
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct AgentControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            SessionListView(model: model, style: .menu)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Used by `install.sh --uninstall` before deleting the bundle.
        if CommandLine.arguments.contains("--unregister-login-item") {
            try? SMAppService.mainApp.unregister()
            NSApp.terminate(nil)
            return
        }
        // Menu bar only, even when launched unbundled during development.
        NSApp.setActivationPolicy(.accessory)

        // UNUserNotificationCenter crashes without a bundle identifier (e.g. `swift run`).
        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            let focus = UNNotificationAction(identifier: "FOCUS", title: "Jump to session", options: [.foreground])
            center.setNotificationCategories([
                UNNotificationCategory(identifier: AppModel.notificationCategory, actions: [focus], intentIdentifiers: []),
            ])
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        AppModel.shared.start()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let key = response.notification.request.content.userInfo["key"] as? String
        Task { @MainActor in
            if let key { AppModel.shared.focus(key: key) }
            completionHandler()
        }
    }
}
