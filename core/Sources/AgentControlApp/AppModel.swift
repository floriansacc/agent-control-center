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
    /// git status runs once per project per scan (30–100 ms each): at most this often.
    private static let gitInterval: TimeInterval = 10

    @Published private(set) var snapshot = Snapshot.empty
    @Published private(set) var launchAtLogin = false
    /// False until the status hook is registered in ~/.claude/settings.json (by install.sh or by the app).
    @Published private(set) var hookInstalled = true
    @Published var notifyOnWaiting: Bool {
        didSet { defaults.set(notifyOnWaiting, forKey: "notifyOnWaiting") }
    }
    @Published var notifyOnDone: Bool {
        didSet { defaults.set(notifyOnDone, forKey: "notifyOnDone") }
    }
    /// Open the Control Center when the app is launched (not when it starts at login).
    @Published var openWindowAtLaunch: Bool {
        didSet { defaults.set(openWindowAtLaunch, forKey: "openWindowAtLaunch") }
    }
    /// Sessions idle or finished for longer than this (seconds) are folded into an "Idle" section; 0 = never.
    @Published var foldIdleAfter: Double {
        didSet { defaults.set(foldIdleAfter, forKey: "foldIdleAfter") }
    }

    static let foldIdleChoices: [(label: String, seconds: Double)] = [
        ("30 minutes", 1800), ("1 hour", 3600), ("3 hours", 10800), ("Never", 0),
    ]

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private var scanning = false
    private var rescanQueued = false
    private var visibleViews = 0
    private var lastPortScan = Date.distantPast
    private var lastGitScan = Date.distantPast
    /// nil until the first scan, so launching the app does not notify about existing sessions.
    private var lastStatuses: [String: SessionStatus]?

    private init() {
        defaults.register(defaults: [
            "notifyOnWaiting": true, "notifyOnDone": false, "foldIdleAfter": 3600.0, "openWindowAtLaunch": true,
        ])
        notifyOnWaiting = defaults.bool(forKey: "notifyOnWaiting")
        notifyOnDone = defaults.bool(forKey: "notifyOnDone")
        openWindowAtLaunch = defaults.bool(forKey: "openWindowAtLaunch")
        foldIdleAfter = defaults.double(forKey: "foldIdleAfter")
    }

    var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    /// Splits the sessions into those shown and those folded away as idle.
    var visibleAndIdleSessions: (visible: [Session], idle: [Session]) {
        guard foldIdleAfter > 0 else { return (snapshot.sessions, []) }
        let now = Date().timeIntervalSince1970
        var visible: [Session] = []
        var idle: [Session] = []
        for s in snapshot.sessions {
            if s.isIdle(longerThan: foldIdleAfter, now: now) { idle.append(s) } else { visible.append(s) }
        }
        return (visible, idle)
    }

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
        HookSetup.refreshInstalledScript(from: Self.bundledHook)
        hookInstalled = HookSetup.isInstalled()
        refresh()
    }

    // MARK: - Hook setup

    private static var bundledHook: URL? { Bundle.main.url(forResource: "agent-status", withExtension: "sh") }

    func setUpHook() {
        let ok = confirm(
            "Set up the Claude Code hook?",
            "Agent Control Center adds a hook to ~/.claude/settings.json so every Claude Code session reports its "
                + "status. Your other settings and hooks are kept, and a backup of the file is saved next to it.\n\n"
                + "Sessions already running start reporting after their next prompt.",
            action: "Set Up"
        )
        guard ok else { return }
        do {
            try HookSetup.install(bundledScript: Self.bundledHook)
            hookInstalled = HookSetup.isInstalled()
        } catch {
            alert("Could not set up the hook", error.localizedDescription)
        }
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
        // Cheap (one small JSON file); picks up `install.sh hook` run while the app is open.
        if !hookInstalled { hookInstalled = HookSetup.isInstalled() }
        if scanning {
            rescanQueued = true
            return
        }
        scanning = true
        // lsof is the costly part: every scan while a list is on screen, else every 30 s.
        let includePorts = visibleViews > 0 || Date().timeIntervalSince(lastPortScan) > Self.backgroundPortInterval
        let includeGit = Date().timeIntervalSince(lastGitScan) >= Self.gitInterval
        Task.detached(priority: .utility) {
            let snap = Scanner.shared.snapshot(ScanOptions(includePorts: includePorts, includeGit: includeGit))
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
        if snap.gitScanned {
            lastGitScan = Date()
        } else {
            let previous = Dictionary(snapshot.sessions.map { ($0.key, $0.git) }, uniquingKeysWith: { a, _ in a })
            for i in snap.sessions.indices { snap.sessions[i].git = previous[snap.sessions[i].key] ?? nil }
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
                post(s, title: "\(s.displayName) needs input", body: s.message ?? "Claude is waiting for you")
            } else if s.status == .done, before == .working, notifyOnDone {
                post(s, title: "\(s.displayName) finished", body: s.lastResponse ?? s.lastPrompt ?? "Claude finished its turn")
            } else if s.status == .error, notifyOnWaiting {
                post(s, title: "\(s.displayName) stopped with an error", body: s.message ?? s.lastResponse ?? s.lastPrompt ?? "")
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
        copy(session.cwd)
    }

    /// `cd <folder> && claude --resume <id>`: picks the conversation up again, e.g. after closing its terminal.
    func copyResumeCommand(_ session: Session) {
        guard let id = session.sessionId else { return }
        let dir = session.rootDir ?? session.cwd
        copy("cd '\(dir.replacingOccurrences(of: "'", with: "'\\''"))' && claude --resume \(id)")
    }

    func revealInFinder(_ session: Session) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Opens the Control Center window, on `session` when given.
    func openControlCenter(_ session: Session? = nil) {
        ControlCenterWindow.shared.show(select: session?.key)
    }

    func openPort(_ listener: Listener) {
        Focus.openPort(listener.port)
    }

    func stop(_ session: Session) {
        guard let pid = session.pid,
              confirm("Stop the Claude session “\(session.displayName)”?", "Sends SIGTERM to pid \(pid).", action: "Stop Session")
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
