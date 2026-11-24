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
            Themed(surfaces: false) { SessionListView(model: model) }
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Started by macOS at login (or by `install.sh`): stay in the menu bar instead of opening the window.
    private var launchedInBackground = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The launch Apple event says whether this is a login item launch; it is only readable at this point.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        // Login items started through SMAppService do not always carry it: right after boot counts as login too.
        launchedInBackground = loginItem || ProcessInfo.processInfo.systemUptime < 120
            || CommandLine.arguments.contains("--background")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Used by `install.sh --uninstall` before deleting the bundle.
        if CommandLine.arguments.contains("--unregister-login-item") {
            try? SMAppService.mainApp.unregister()
            NSApp.terminate(nil)
            return
        }
        // Menu bar only, even when launched unbundled during development; the Dock setting may change it.
        NSApp.setActivationPolicy(.accessory)
        AppShell.shared.installMainMenu()
        AppShell.shared.update()
        _ = ThemeStore.shared

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
        StatusItemMenu.shared.install()
        MenuBarAppearance.shared.attach()
        if CommandLine.arguments.contains("--settings") {
            SettingsWindow.shared.show()
        } else if CommandLine.arguments.contains("--control-center")
            || (AppModel.shared.openWindowAtLaunch && !launchedInBackground) {
            // Opened like a regular app (Finder, Spotlight, the Dock): show the window.
            AppModel.shared.openControlCenter()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Waiting permission hooks stop waiting for us (they also notice the pid is gone).
        Approvals.setEnabled(false)
    }

    /// Launching the app again (Spotlight, Finder, `open -a`) while it runs opens the Control Center.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.openControlCenter() }
        return false
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
