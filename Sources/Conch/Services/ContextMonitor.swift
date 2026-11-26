import AppKit
import Combine
import Foundation

/// One statusline report from Claude Code, as the wrapper saved it.
struct ContextReading: Equatable {
    /// nil until Claude Code has a usage figure (at startup, and right after /clear).
    var usedPercent: Double?
    var windowTokens: Int?
    var claudeSessionID: UUID?
    /// The session's project folder (`workspace.project_dir`, else `cwd`).
    var directory: String?
    /// Changes with each user prompt. Missing until the session has sent one.
    var promptID: String?
    var modelID: String?
    var modelName: String?
    /// Cumulative for the Claude session at API prices, as Claude Code prices it. A resumed session starts from
    /// the conversation's earlier total.
    var totalCost: Double?
    /// The latest API call (`context_window.current_usage`).
    var tokens: UsageTokens?
    /// Account wide plan limits. Present only after the session has made a request.
    var fiveHour: RateLimitReading?
    var sevenDay: RateLimitReading?

    init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let window = object["context_window"] as? [String: Any]
        usedPercent = (window?["used_percentage"] as? NSNumber)?.doubleValue
        windowTokens = (window?["context_window_size"] as? NSNumber)?.intValue
        claudeSessionID = (object["session_id"] as? String).flatMap(UUID.init(uuidString:))
        let workspace = object["workspace"] as? [String: Any]
        directory = workspace?["project_dir"] as? String ?? object["cwd"] as? String

        promptID = (object["prompt_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let model = object["model"] as? [String: Any]
        modelID = (model?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        modelName = (model?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let cost = ((object["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue
        totalCost = cost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        if let usage = window?["current_usage"] as? [String: Any] {
            let count = { (key: String) in (usage[key] as? NSNumber)?.intValue ?? 0 }
            tokens = UsageTokens(input: count("input_tokens"), cacheRead: count("cache_read_input_tokens"),
                                 cacheWrite: count("cache_creation_input_tokens"), output: count("output_tokens"))
        }
        let limits = object["rate_limits"] as? [String: Any]
        fiveHour = RateLimitReading(limits?["five_hour"])
        sevenDay = RateLimitReading(limits?["seven_day"])
    }
}

/// One plan limit from a report's `rate_limits`.
struct RateLimitReading: Equatable {
    var usedPercent: Double
    var resetsAt: Date

    init(usedPercent: Double, resetsAt: Date) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// `resets_at` is Unix seconds. A value too large for seconds is read as milliseconds.
    init?(_ value: Any?) {
        guard let object = value as? [String: Any],
              let percent = (object["used_percentage"] as? NSNumber)?.doubleValue, percent.isFinite,
              let reset = (object["resets_at"] as? NSNumber)?.doubleValue, reset.isFinite, reset > 0 else { return nil }
        usedPercent = max(percent, 0)
        resetsAt = Date(timeIntervalSince1970: reset > 100_000_000_000 ? reset / 1000 : reset)
    }
}

/// Tokens of one API call, split the way Claude Code reports them.
struct UsageTokens: Equatable {
    var input: Int
    var cacheRead: Int
    var cacheWrite: Int
    var output: Int
}

/// Watches the folder the statusline wrapper writes to and maps each file to its Claude session: sets
/// `session.context`, and follows the conversation Claude Code reports (it changes after /clear or /resume) so a
/// relaunch resumes the one in use.
@MainActor
final class ContextMonitor {
    static let shared = ContextMonitor(
        directory: ContextStatusLine.contextDirectory,
        sessions: { SessionStore.shared.allSessions },
        sessionsChanged: SessionStore.shared.$groups.map { _ in () }.eraseToAnyPublisher(),
        usage: .shared
    )

    let directory: URL
    private let sessions: () -> [TerminalSession]
    private let sessionsChanged: AnyPublisher<Void, Never>
    /// Gets every applied reading, for plan limits and cost.
    private let usage: UsageMonitor?

    private var source: DispatchSourceFileSystemObject?
    private var scanScheduled = false
    /// Modification date of the file last applied per session, so unchanged files are not parsed again.
    private var appliedDates: [UUID: Date] = [:]
    private var directories: [UUID: String] = [:]
    /// Conversation each session was on when Conch sent /clear. Claude Code can report it once more right after
    /// the clear, with its old usage, and that reading would put the meter straight back.
    private var clearedConversations: [UUID: UUID] = [:]
    private var sessionsObserver: AnyCancellable?
    private var foregroundObservers: [UUID: AnyCancellable] = [:]

    init(directory: URL, sessions: @escaping () -> [TerminalSession], sessionsChanged: AnyPublisher<Void, Never>,
         usage: UsageMonitor? = nil) {
        self.directory = directory
        self.sessions = sessions
        self.sessionsChanged = sessionsChanged
        self.usage = usage
    }

    /// The project folder Claude Code last reported for a session.
    func directory(for session: TerminalSession) -> String? {
        directories[session.id]
    }

    /// Conch just sent /clear: the reading is out of date until Claude Code reports the new conversation.
    func noteCleared(_ session: TerminalSession) {
        if let conversation = session.context?.claudeSessionID ?? session.spec.claude?.sessionID {
            clearedConversations[session.id] = conversation
        }
        session.context = nil
    }

    func start() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removeFilesFromEarlierRuns()
        watchDirectory()
        sessionsObserver = sessionsChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.observeForegroundProcesses()
                self?.scheduleScan()
            }
        scan()
    }

    func stop() {
        source?.cancel()
        source = nil
        sessionsObserver = nil
        foregroundObservers.removeAll()
    }

    /// Reads every changed file now. Also drops files whose session is gone.
    func scan() {
        scanScheduled = false
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        let byID = Dictionary(sessions().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for name in names {
            let url = directory.appendingPathComponent(name)
            if name.hasPrefix(".") {
                // A wrapper killed between writing and renaming leaves its temp file behind.
                if let modified = modificationDate(url), modified.timeIntervalSinceNow < -60 {
                    try? fileManager.removeItem(at: url)
                }
                continue
            }
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))) else { continue }
            guard let session = byID[id] else {
                try? fileManager.removeItem(at: url)
                appliedDates[id] = nil
                directories[id] = nil
                clearedConversations[id] = nil
                usage?.forget(session: id)
                continue
            }
            guard session.spec.kind == .claude, let modified = modificationDate(url),
                  modified != appliedDates[id] else { continue }
            appliedDates[id] = modified
            guard let data = try? Data(contentsOf: url), let reading = ContextReading(json: data) else { continue }
            apply(reading, updated: modified, to: session)
        }
    }

    // MARK: - Private

    private func apply(_ reading: ContextReading, updated: Date, to session: TerminalSession) {
        if let directory = reading.directory { directories[session.id] = directory }
        if let cleared = clearedConversations[session.id] {
            guard let conversation = reading.claudeSessionID, conversation != cleared else { return }
            clearedConversations[session.id] = nil
        }
        self.usage?.record(reading, updated: updated, session: session.id)
        let usage = reading.usedPercent.map {
            ContextUsage(usedPercent: min(max($0, 0), 100), windowTokens: reading.windowTokens,
                         claudeSessionID: reading.claudeSessionID, updated: updated)
        }
        let current = session.context
        if usage?.usedPercent != current?.usedPercent || usage?.windowTokens != current?.windowTokens
            || usage?.claudeSessionID != current?.claudeSessionID {
            session.context = usage
        }
        if let id = reading.claudeSessionID {
            SessionStore.shared.followClaudeConversation(session, to: id)
        }
        if let name = reading.modelName, session.modelName != name { session.modelName = name }
        if let model = reading.modelID {
            SessionStore.shared.followReportedModel(session, to: model)
        }
    }

    private func watchDirectory() {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("Conch: cannot watch %@ for context use", directory.path)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let folderGone = source.map { !$0.data.isDisjoint(with: [.delete, .rename]) } ?? false
            MainActor.assumeIsolated {
                guard let self else { return }
                if folderGone {
                    // The descriptor follows the old folder. The wrapper recreates it by path, so watch the new one.
                    self.source?.cancel()
                    self.source = nil
                    try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                    self.watchDirectory()
                }
                self.scheduleScan()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    /// The wrapper writes a temp file and renames it, two folder events per report, so scans are coalesced.
    private func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
    }

    /// Every session restarts with the app, and its first report comes within a second or two. Older readings
    /// would only flash in the sidebar until then.
    private func removeFilesFromEarlierRuns() {
        let launched = NSRunningApplication.current.launchDate ?? Date()
        let fileManager = FileManager.default
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let url = directory.appendingPathComponent(name)
            if let modified = modificationDate(url), modified < launched {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// When claude exits to the shell prompt, its last reading no longer describes anything running.
    private func observeForegroundProcesses() {
        let claudeSessions = sessions().filter { $0.spec.kind == .claude }
        let ids = Set(claudeSessions.map(\.id))
        foregroundObservers = foregroundObservers.filter { ids.contains($0.key) }
        for session in claudeSessions where foregroundObservers[session.id] == nil {
            foregroundObservers[session.id] = session.$foregroundProcess
                .removeDuplicates()
                .sink { [weak session] process in
                    guard process == nil, let session else { return }
                    if session.context != nil { session.context = nil }
                    if session.modelName != nil { session.modelName = nil }
                }
        }
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
