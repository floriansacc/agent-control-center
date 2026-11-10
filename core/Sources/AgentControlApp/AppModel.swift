import AgentCore
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let notificationCategory = "SESSION"

    /// Scan cadence; hook status changes also trigger an immediate scan through the directory watcher.
    private static let interval: TimeInterval = 3
    /// lsof is the expensive part: run it every scan only while a list is on screen.
    private static let backgroundPortInterval: TimeInterval = 30

    @Published private(set) var snapshot = Snapshot.empty
    @Published private(set) var panelVisible = false
    @Published private(set) var launchAtLogin = false
    @Published var notifyOnWaiting: Bool {
        didSet { defaults.set(notifyOnWaiting, forKey: "notifyOnWaiting") }
    }
    @Published var notifyOnDone: Bool {
        didSet { defaults.set(notifyOnDone, forKey: "notifyOnDone") }
    }

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private var scanning = false
    private var rescanQueued = false
    private var visibleViews = 0
    private var lastPortScan = Date.distantPast
    /// nil until the first scan, so launching the app does not notify about existing sessions.
    private var lastStatuses: [String: SessionStatus]?
    private lazy var panel: FloatingPanel = {
        let panel = FloatingPanel(rootView: SessionListView(model: self, style: .panel))
        panel.onClose = { [weak self] in self?.panelClosed() }
        return panel
    }()

    private init() {
        defaults.register(defaults: ["notifyOnWaiting": true, "notifyOnDone": false])
        notifyOnWaiting = defaults.bool(forKey: "notifyOnWaiting")
        notifyOnDone = defaults.bool(forKey: "notifyOnDone")
    }

    var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    func start() {
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.refresh() }
        }
        // .common keeps it firing while a menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        watchStatusDirectory()

        if isBundled {
            if !defaults.bool(forKey: "didSetupLoginItem") {
                defaults.set(true, forKey: "didSetupLoginItem")
                setLaunchAtLogin(true)
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        if defaults.bool(forKey: "panelOpen") { showPanel() }
        refresh()
    }

    // MARK: - Scanning

    func viewAppeared() {
        visibleViews += 1
        refresh()
    }

    func viewDisappeared() {
        visibleViews = max(0, visibleViews - 1)
    }

    func refresh() {
        if scanning {
            rescanQueued = true
            return
        }
        scanning = true
        let includePorts = visibleViews > 0 || Date().timeIntervalSince(lastPortScan) > Self.backgroundPortInterval
        Task.detached(priority: .utility) {
            let snap = Scanner.shared.snapshot(ScanOptions(includePorts: includePorts))
            await MainActor.run { AppModel.shared.apply(snap) }
        }
    }

    private func apply(_ fresh: Snapshot) {
        var snap = fresh
        if snap.portsScanned {
            lastPortScan = Date()
        } else {
            // Keep the last known ports so they don't flicker away between port scans.
            let previous = Dictionary(snapshot.sessions.map { ($0.key, $0.ports) }, uniquingKeysWith: { a, _ in a })
            for i in snap.sessions.indices { snap.sessions[i].ports = previous[snap.sessions[i].key] ?? [] }
            snap.otherPorts = snapshot.otherPorts
        }
        notifyTransitions(snap)
        snapshot = snap
        scanning = false
        if rescanQueued {
            rescanQueued = false
            refresh()
        }
    }

    private func watchStatusDirectory() {
        let dir = Paths.statusDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        // Directory .write fires on create / delete / rename, which covers the hook's atomic `mv`.
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.debounce?.cancel()
            let work = DispatchWorkItem { AppModel.shared.refresh() }
            self.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    // MARK: - Notifications

    private func notifyTransitions(_ snap: Snapshot) {
        let previous = lastStatuses
        lastStatuses = Dictionary(snap.sessions.map { ($0.key, $0.status) }, uniquingKeysWith: { a, _ in a })
        guard let previous, isBundled else { return }
        for s in snap.sessions {
            guard let before = previous[s.key], before != s.status else { continue }
            if s.status == .waiting, notifyOnWaiting {
                post(s, title: "\(s.project) needs input", body: s.message ?? "Claude is waiting for you")
            } else if s.status == .done, before == .working, notifyOnDone {
                post(s, title: "\(s.project) finished", body: s.lastResponse ?? s.lastPrompt ?? "Claude finished its turn")
            } else if s.status == .error, notifyOnWaiting {
                post(s, title: "\(s.project) stopped with an error", body: s.message ?? s.lastResponse ?? s.lastPrompt ?? "")
            }
        }
    }

    private func post(_ s: Session, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.subtitle = [s.branch, s.host.label].compactMap { $0 }.joined(separator: " · ")
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = ["key": s.key]
        // One live notification per session: a newer state replaces the older banner.
        let request = UNNotificationRequest(identifier: s.key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Actions

    func focus(key: String) {
        if let s = snapshot.sessions.first(where: { $0.key == key }) { focus(s) }
    }

    func focus(_ session: Session) {
        Task.detached {
            let result = Focus.focus(session)
            await MainActor.run {
                switch result {
                case .focused: break
                case .notFound: NSSound.beep()
                case .automationDenied:
                    AppModel.shared.alert(
                        "Allow Agent Control Center to control iTerm",
                        "System Settings → Privacy & Security → Automation → Agent Control Center → enable iTerm."
                    )
                }
            }
        }
    }

    func openFolder(_ session: Session) {
        let dir = session.cwd
        Task.detached { Focus.openInVSCode(dir) }
    }

    func copyPath(_ session: Session) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.cwd, forType: .string)
    }

    func openPort(_ listener: Listener) {
        Focus.openPort(listener.port)
    }

    func stop(_ session: Session) {
        guard let pid = session.pid,
              confirm("Stop the Claude session in \(session.project)?", "Sends SIGTERM to pid \(pid).", action: "Stop Session")
        else { return }
        if let error = Focus.terminate(pid: pid) { alert("Could not stop pid \(pid)", error) }
        refresh()
    }

    func stop(_ listener: Listener) {
        guard confirm("Stop \(listener.command) on :\(listener.port)?", "Sends SIGTERM to pid \(listener.pid).", action: "Stop Process")
        else { return }
        if let error = Focus.terminate(pid: listener.pid) { alert("Could not stop pid \(listener.pid)", error) }
        refresh()
    }

    // MARK: - Panel

    func togglePanel() {
        panelVisible ? panel.close() : showPanel()
    }

    func showPanel() {
        panel.orderFrontRegardless()
        panelVisible = true
        defaults.set(true, forKey: "panelOpen")
    }

    private func panelClosed() {
        panelVisible = false
        defaults.set(false, forKey: "panelOpen")
    }

    // MARK: - Settings

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[AgentControl] launch at login: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Dialogs

    private func confirm(_ title: String, _ message: String, action: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
