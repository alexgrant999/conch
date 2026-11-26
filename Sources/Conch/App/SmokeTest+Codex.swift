import Foundation

// Owner: codex builder (feature/codex).

extension SmokeTest {
    /// Smoke check 21. Never runs codex: argv is built, not run, and Codex's session files are faked in a throwaway
    /// CODEX_HOME.
    func checkCodex(directory: String) async {
        var failures: [String] = []
        let home = URL(fileURLWithPath: directory).appendingPathComponent("codex-home", isDirectory: true)
        let previousHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("CODEX_HOME", home.path, 1)
        defer {
            if let previousHome { setenv("CODEX_HOME", previousHome, 1) } else { unsetenv("CODEX_HOME") }
            try? FileManager.default.removeItem(at: home)
        }

        // Launch: plain, with a first message after "--", and resume once Codex has the session's file.
        var spec = LaunchSpec.codex(directory)
        if LaunchCommand.claudeArgv(for: spec, displayName: "Smoke", restoring: false) != ["codex"] {
            failures.append("new codex argv \(LaunchCommand.codexArgv(for: spec))")
        }
        spec.codex?.initialPrompt = "-v review the diff"
        if LaunchCommand.codexArgv(for: spec) != ["codex", "--", "-v review the diff"] {
            failures.append("prompt argv \(LaunchCommand.codexArgv(for: spec))")
        }
        let id = "01a20a19-31f1-75b1-b24f-1a6b0f788bf0"
        spec.codex?.sessionID = id
        if LaunchCommand.codexArgv(for: spec).first(where: { $0 == "resume" }) != nil {
            failures.append("resumed a session whose file is gone")
        }
        let now = Date()
        // In another folder, so the tracker check below does not see it as a candidate.
        writeRollout(home: home, id: id, cwd: "/var/empty", started: now)
        if LaunchCommand.codexArgv(for: spec) != ["codex", "resume", id] {
            failures.append("resume argv \(LaunchCommand.codexArgv(for: spec))")
        }

        // Old state without the codex key still loads, and layouts never carry a session id or message.
        let old = #"{"kind":"claude","cwd":"\#(directory)","claude":{"sessionID":"\#(UUID().uuidString)","remoteControl":false,"extraArgs":[]}}"#
        if (try? JSONDecoder().decode(LaunchSpec.self, from: Data(old.utf8)))?.codex != nil { failures.append("old spec decoded with codex options") }
        let saved = LayoutPane.saving(spec, customName: nil, liveDirectory: directory)
        if saved?.spec.kind != .codex || saved?.spec.codex?.sessionID != nil || saved?.spec.codex?.initialPrompt != nil {
            failures.append("layout pane \(String(describing: saved?.spec))")
        }

        failures += checkCodexTracker(home: home, directory: directory, now: now)

        // Review: who reviews whom, where the note goes, and one-line prompts that name it.
        let claude = TerminalSession(spec: .claude(directory, remoteControl: false))
        let codex = TerminalSession(spec: .codex(directory))
        if ReviewActions.reviewerKind(for: claude) != .codex || ReviewActions.reviewerKind(for: codex) != .claude
            || ReviewActions.reviewerKind(for: TerminalSession(spec: .shell(directory))) != nil {
            failures.append("reviewer kinds are wrong")
        }
        let note = ReviewActions.noteURL(in: directory, reviewer: .codex)
        if !note.path.hasPrefix(directory + "/.conch/reviews/review-") || !note.path.hasSuffix("-codex.md") {
            failures.append("review note at \(note.path)")
        }
        for prompt in [ReviewActions.requestPrompt(author: .claude, note: note), ReviewActions.deliveryPrompt(reviewer: .codex, note: note)]
        where prompt.contains("\n") || !prompt.contains(note.path) {
            failures.append("a review prompt is not one line naming the note: \(prompt)")
        }
        if codex.defaultName != "Codex" || SessionGlyph.symbol(for: .codex) != "hexagon" { failures.append("codex name or glyph") }

        record("21 codex", failures.isEmpty,
               failures.isEmpty ? "argv (new, first message, resume), old state, layouts, session id tracking and review prompts all hold"
                   : failures.joined(separator: "; "))
    }

    /// Ids go to the session in the same folder, oldest first, never to a file started well before Conch saw the
    /// session or to one in another folder.
    private func checkCodexTracker(home: URL, directory: String, now: Date) -> [String] {
        var failures: [String] = []
        let other = URL(fileURLWithPath: directory).appendingPathComponent("elsewhere").path
        try? FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        let (a, b) = (TerminalSession(spec: .codex(directory)), TerminalSession(spec: .codex(directory)))
        var assigned: [UUID: String] = [:]
        let tracker = CodexSessionTracker(sessions: { [a, b] }, assign: { session, id in
            assigned[session.id] = id
            session.updateSpec { $0.codex?.sessionID = id }
        })
        let (old, foreign, first, second) = ("0a000000-0000-7000-8000-000000000001", "0a000000-0000-7000-8000-000000000002",
                                             "0a000000-0000-7000-8000-000000000003", "0a000000-0000-7000-8000-000000000004")
        tracker.tick(now: now)
        writeRollout(home: home, id: old, cwd: directory, started: now.addingTimeInterval(-600))
        writeRollout(home: home, id: foreign, cwd: other, started: now.addingTimeInterval(1))
        writeRollout(home: home, id: second, cwd: directory, started: now.addingTimeInterval(3))
        writeRollout(home: home, id: first, cwd: directory, started: now.addingTimeInterval(2))
        tracker.tick(now: now.addingTimeInterval(5))
        if assigned[a.id] != first || assigned[b.id] != second {
            failures.append("tracker assigned \(assigned[a.id] ?? "none") and \(assigned[b.id] ?? "none"), expected \(first) and \(second)")
        }
        return failures
    }

    private func writeRollout(home: URL, id: String, cwd: String, started: Date) {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: started)
        let folder = home.appendingPathComponent("sessions/" + String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let meta: [String: Any] = ["type": "session_meta",
                                   "payload": ["id": id, "cwd": cwd, "timestamp": formatter.string(from: started),
                                               "base_instructions": ["text": "long"]]]
        guard let line = try? JSONSerialization.data(withJSONObject: meta) else { return }
        try? (line + Data("\n{\"type\":\"event\"}\n".utf8)).write(to: folder.appendingPathComponent("rollout-x-\(id).jsonl"))
    }
}
