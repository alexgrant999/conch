import Foundation

// Owner: codex builder (feature/codex).

/// One Codex session file: `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<local time>-<id>.jsonl`, whose first line is
/// the session's `session_meta` (its id, folder and start time).
struct CodexRollout: Equatable {
    let id: String
    let cwd: String
    let started: Date
}

enum CodexSessions {
    /// `$CODEX_HOME`, else ~/.codex.
    static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom.expandingTilde, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".codex", isDirectory: true)
    }

    static var sessionsDirectory: URL { home.appendingPathComponent("sessions", isDirectory: true) }

    /// True when a session file for this id is under the sessions folder.
    static func rolloutExists(id: String) -> Bool {
        let id = id.lowercased()
        guard !id.isEmpty, id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return false }
        let suffix = "-\(id).jsonl"
        let enumerator = FileManager.default.enumerator(at: sessionsDirectory, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent.hasSuffix(suffix) { return true }
        }
        return false
    }

    /// Sessions whose file changed since `since`, from the day folders between `since` and `now` (local dates, the
    /// way Codex names them), at most four days.
    static func recentRollouts(since: Date, now: Date = Date()) -> [CodexRollout] {
        let fileManager = FileManager.default
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: since)
        var result: [CodexRollout] = []
        for _ in 0..<4 where day <= now {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = sessionsDirectory.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0,
                                                                         parts.month ?? 0, parts.day ?? 0))
            let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                              options: [.skipsHiddenFiles])) ?? []
            for file in files where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard (modified ?? .distantPast) >= since, let rollout = meta(of: file) else { continue }
                result.append(rollout)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// The first line's `session_meta`. Only the head is read: the line carries the base instructions, but the
    /// rest of the file can run to many megabytes.
    static func meta(of file: URL) -> CodexRollout? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1 << 20),
              let line = head.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String, !id.isEmpty,
              let cwd = payload["cwd"] as? String, !cwd.isEmpty else { return nil }
        let stamp = (payload["timestamp"] as? String).flatMap(parseDate)
        let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        return CodexRollout(id: id.lowercased(), cwd: cwd, started: stamp ?? created ?? .distantPast)
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Learns each Codex session's id from the session file Codex writes, so a relaunch can resume it. Codex picks its
/// own ids, unlike Claude Code's `--session-id`. A session without one is matched to the oldest unclaimed file for
/// its folder that Codex started no earlier than 30 seconds before Conch first saw the session.
@MainActor
final class CodexSessionTracker {
    static let shared = CodexSessionTracker(sessions: { SessionStore.shared.allSessions },
                                            assign: { SessionStore.shared.setCodexSessionID($0, to: $1) })

    private let sessions: () -> [TerminalSession]
    private let assign: (TerminalSession, String) -> Void
    private var firstSeen: [UUID: Date] = [:]
    private var timer: Timer?

    init(sessions: @escaping () -> [TerminalSession], assign: @escaping (TerminalSession, String) -> Void) {
        self.sessions = sessions
        self.assign = assign
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Reads the session folders only while some Codex session has no id yet.
    func tick(now: Date = Date()) {
        let codex = sessions().filter { $0.spec.kind == .codex }
        let live = Set(codex.map(\.id))
        firstSeen = firstSeen.filter { live.contains($0.key) }
        let pending = codex.filter { $0.spec.codex?.sessionID == nil }
        for session in pending where firstSeen[session.id] == nil { firstSeen[session.id] = now }
        guard let earliest = pending.compactMap({ firstSeen[$0.id] }).min() else { return }

        var claimed = Set(codex.compactMap { $0.spec.codex?.sessionID?.lowercased() })
        let rollouts = CodexSessions.recentRollouts(since: earliest.addingTimeInterval(-30), now: now)
            .sorted { $0.started < $1.started }
        for session in pending.sorted(by: { (firstSeen[$0.id] ?? now) < (firstSeen[$1.id] ?? now) }) {
            let seen = firstSeen[session.id] ?? now
            let folder = Self.canonical(session.spec.cwd)
            guard let match = rollouts.first(where: {
                !claimed.contains($0.id) && Self.canonical($0.cwd) == folder && $0.started >= seen.addingTimeInterval(-30)
            }) else { continue }
            claimed.insert(match.id)
            assign(session, match.id)
        }
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
