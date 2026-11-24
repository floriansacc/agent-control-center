import AgentCore
import Foundation

/// State of the Control Center window: the selected session and its conversation, kept live by watching
/// the transcript file. Lives only while the window is open.
@MainActor
final class ControlCenterModel: ObservableObject {
    enum Conversation: Equatable {
        case none
        case loading
        /// The session has no transcript (yet): untracked, or nothing sent so far.
        case missing
        case loaded([TranscriptEntry])
    }

    @Published var selection: String?
    @Published private(set) var conversation = Conversation.none
    /// The sessions in sidebar order (folded ones left out), kept up to date by the sidebar.
    var orderedKeys: [String] = []

    private let queue = DispatchQueue(label: "agent-control.transcript", qos: .userInitiated)
    private var reader: TranscriptReader?
    /// The session and transcript path the reader was made for.
    private var loadedKey: String?
    private var loadedPath: String?
    private var watcher: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    /// Bumped on every new load, so results for a session no longer selected are dropped.
    private var generation = 0

    init(selection: String?) {
        self.selection = selection
    }

    /// ⌘1–⌘9: the nth session in the sidebar.
    func selectNumber(_ n: Int) -> Bool {
        guard n >= 1, n <= orderedKeys.count else { return false }
        selection = orderedKeys[n - 1]
        return true
    }

    /// Follows the selected session: loads its transcript when it changes, re-reads it when the hook reports
    /// a new event (the file watcher normally gets there first).
    func sync(with session: Session?) {
        guard let session else {
            stop()
            conversation = .none
            loadedKey = nil
            loadedPath = nil
            return
        }
        if session.key == loadedKey, session.transcriptPath == loadedPath, reader != nil {
            scheduleRead()
            return
        }
        load(session)
    }

    private func load(_ session: Session) {
        stop()
        generation += 1
        let generation = generation
        loadedKey = session.key
        loadedPath = session.transcriptPath
        reader = nil
        conversation = .loading
        queue.async {
            let reader = Transcript.url(for: session).map(TranscriptReader.init)
            reader?.update()
            let entries = reader?.entries
            Task { @MainActor in
                guard generation == self.generation else { return }
                self.reader = reader
                self.conversation = entries.map { .loaded($0) } ?? .missing
                if let reader { self.watch(reader.url) }
            }
        }
    }

    private func scheduleRead() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.read() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func read() {
        guard let reader else { return }
        let generation = generation
        queue.async {
            guard reader.update() else { return }
            let entries = reader.entries
            Task { @MainActor in
                guard generation == self.generation else { return }
                self.conversation = .loaded(entries)
            }
        }
    }

    private func watch(_ url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) {
                // Replaced: reopen it from scratch on the next sync.
                self.stop()
                self.reader = nil
                self.loadedKey = nil
            } else {
                self.scheduleRead()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        debounce?.cancel()
    }
}
