import AppKit

// Owner: shell agent.

/// `Conch --smoke-test <result.json>`. Runs end-to-end checks against real ptys, writes
/// `{"passed": Bool, "checks": [{"name", "ok", "detail"}]}` and exits 0 when all pass, 1 otherwise, 2 on timeout.
///
/// Every step is an async step on the main actor. The main thread never sleeps, because pty output reaches the
/// terminal through the main run loop.
@MainActor
final class SmokeTest {
    private static let timeout: TimeInterval = 90

    let store: SessionStore
    private let results: SmokeResults

    /// The result path when the arguments ask for a smoke test, else nil.
    nonisolated static func resultPath(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--smoke-test") else { return nil }
        let next = arguments.index(after: index)
        if next < arguments.endIndex, !arguments[next].hasPrefix("--") { return arguments[next] }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("conch-smoke-result.json")
    }

    /// Points persistence at a throwaway file when the runner did not, so a smoke test can never touch real state.
    /// Call before anything reads Persistence.
    nonisolated static func isolateState() {
        let current = ProcessInfo.processInfo.environment["CONCH_STATE_PATH"] ?? ""
        guard current.isEmpty else { return }
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("conch-smoke-state-\(UUID().uuidString).json")
        setenv("CONCH_STATE_PATH", path, 1)
    }

    init(resultPath: String, store: SessionStore) {
        self.store = store
        self.results = SmokeResults(path: resultPath)
    }

    func start() {
        let results = results
        let timeout = Self.timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            results.finish(exitCode: 2, extra: SmokeCheck(name: "timeout", ok: false,
                                                          detail: "did not finish within \(Int(timeout)) s"))
        }
        Task { @MainActor in
            await self.runAll()
        }
    }

    // MARK: - Checks

    private func runAll() async {
        let expectedState = ProcessInfo.processInfo.environment["CONCH_STATE_PATH"] ?? ""
        let statePath = Persistence.stateURL.standardizedFileURL.path
        guard !expectedState.isEmpty,
              statePath == URL(fileURLWithPath: expectedState.expandingTilde).standardizedFileURL.path else {
            record("state isolation", false, "Persistence.stateURL is \(statePath), expected CONCH_STATE_PATH \(expectedState)")
            results.finish(exitCode: 1, extra: nil)
            return
        }

        let directory: String
        do {
            directory = try makeTemporaryDirectory()
        } catch {
            record("temp directory", false, "\(error)")
            results.finish(exitCode: 1, extra: nil)
            return
        }

        // 1. A shell starts in the temp dir and runs a command.
        let shell = store.newShell(in: directory)
        _ = await waitUntil(4) { !shell.bufferText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        await pause(0.3)
        shell.send(text: "echo CONCH_SMOKE_$((40+2))\r")
        let echoed = await waitUntil(8) { shell.bufferText().contains("CONCH_SMOKE_42") }
        record("1 shell runs a command", echoed,
               echoed ? "CONCH_SMOKE_42 in buffer" : "buffer tail: \(tail(shell.bufferText()))")

        // 2. libproc reports the shell's working directory.
        var liveDirectory = ""
        let cwdMatches = await waitUntil(3) {
            shell.refreshProcessInfo()
            liveDirectory = shell.currentDirectory
            return canonical(liveDirectory) == canonical(directory)
        }
        record("2 live working directory", cwdMatches,
               "currentDirectory \(liveDirectory), expected \(canonical(directory))")

        // 3. A running child is detected and named.
        shell.send(text: "sleep 3\r")
        await pause(0.7)
        var running = false
        var foreground: String?
        let childSeen = await waitUntil(1.5) {
            shell.refreshProcessInfo()
            running = shell.hasRunningChild
            foreground = shell.foregroundProcess
            return running && foreground == "sleep"
        }
        record("3 running child", childSeen,
               "hasRunningChild \(running), foregroundProcess \(foreground ?? "nil")")

        // 4. Split right adds a second pane to the selected group.
        let split = store.newShell(split: true)
        let selected = store.selectedGroup
        let splitOK = selected?.sessions.count == 2
            && selected?.sessions.contains { $0 === shell } == true
            && selected?.sessions.contains { $0 === split } == true
        record("4 split right", splitOK,
               "groups \(store.groups.count), selected group sessions \(selected?.sessions.count ?? 0)")

        // 4b. Each pty master closes on exec, so a later session's processes cannot hold or read an earlier one.
        let leaky = [shell, split].filter { session in
            guard let fd = session.view.process?.childfd, fd >= 0 else { return true }
            return fcntl(fd, F_GETFD) & FD_CLOEXEC == 0
        }
        record("4b pty not inherited", leaky.isEmpty, "\(leaky.count) of 2 pty masters inheritable")

        // 5. Launch command rules.
        let (launchOK, launchDetail) = checkLaunchCommand(directory: directory)
        record("5 launch command", launchOK, launchDetail)
        let copyFailures = checkCopyCleanup()
        record("5b copy cleanup", copyFailures.isEmpty, copyFailures.joined(separator: "; "))

        // 6. Saved state round-trips.
        store.save()
        let loaded = Persistence.load()
        let savedOK = loaded?.groups.count == 1 && loaded?.groups.first?.sessions.count == 2
        record("6 save and load", savedOK,
               loaded.map { "groups \($0.groups.count), sessions \($0.groups.map(\.sessions.count))" } ?? "load returned nil")

        // 7. Closing the split pane leaves one session in the group.
        store.close(split)
        let remaining = store.group(containing: shell)?.sessions.count ?? 0
        let closeOK = store.groups.count == 1 && remaining == 1
        record("7 close split", closeOK, "groups \(store.groups.count), sessions in group \(remaining)")

        // 8. The login shell puts claude on PATH even when the app started with a minimal environment.
        _ = await waitUntil(4) { !shell.hasRunningChild }
        shell.send(text: "echo CONCH_CLAUDE_PATH=$(command -v claude)\r")
        var claudePath: String?
        let found = await waitUntil(6) {
            claudePath = markedPath(in: shell.bufferText())
            return claudePath != nil
        }
        record("8 claude on login PATH", found,
               claudePath.map { "command -v claude: \($0)" } ?? "no absolute path, buffer tail: \(tail(shell.bufferText()))")

        // 11 to 19: one check per feature added after v0.1, each in its own SmokeTest+<Feature>.swift.
        await checkRecentConversations(directory: directory)
        await checkAttentionJump(directory: directory)
        await checkLayouts(directory: directory)
        await checkWorktree(directory: directory)
        await checkContext(directory: directory)
        await checkModules(directory: directory)
        await checkUsage(directory: directory)
        await checkOlder(directory: directory)
        await checkProjectIcons(directory: directory)

        // 9. Closing a pane kills a foreground job that ignores SIGHUP and SIGTERM (servers reload on SIGHUP).
        let closedJob = await startStubbornJob(in: directory)
        if let closedJob {
            store.close(closedJob.session)
            let gone = await waitUntil(4) { killpg(closedJob.group, 0) != 0 }
            record("9 close kills stubborn job", gone, gone ? "job group \(closedJob.group) gone" : "job group \(closedJob.group) still alive")
        } else {
            record("9 close kills stubborn job", false, "job did not start")
        }

        // 10. Quitting kills such a job too, even though the delayed kill never gets to run.
        let quitJob = await startStubbornJob(in: directory)
        store.terminateAll()
        if let quitJob {
            let gone = await waitUntil(1) { killpg(quitJob.group, 0) != 0 }
            record("10 quit kills stubborn job", gone, gone ? "job group \(quitJob.group) gone" : "job group \(quitJob.group) still alive")
        } else {
            record("10 quit kills stubborn job", false, "job did not start")
        }

        try? FileManager.default.removeItem(atPath: directory)
        results.finish(exitCode: results.allPassed ? 0 : 1, extra: nil)
    }

    /// A new shell running `sleep` with SIGHUP and SIGTERM ignored, and the job's process group.
    private func startStubbornJob(in directory: String) async -> (session: TerminalSession, group: pid_t)? {
        let session = store.newShell(in: directory)
        _ = await waitUntil(4) { !session.bufferText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        await pause(0.3)
        session.send(text: "sh -c 'trap \"\" HUP TERM; exec sleep 4321'\r")
        var group: pid_t?
        _ = await waitUntil(4) {
            session.refreshProcessInfo()
            guard session.foregroundProcess == "sleep", let fd = session.view.process?.childfd else { return false }
            group = ProcessInspector.foregroundProcessGroup(ptyFD: fd)
            return group != nil
        }
        return group.map { (session, $0) }
    }

    private func checkCopyCleanup() -> [String] {
        let cases: [(name: String, raw: String, expected: String)] = [
            ("wrapped paragraph",
             "\u{23FA} Here is the message:\n\n  Hi Sam, thanks for getting back to me\n  about the proposal. Happy to talk it\n  over on Friday.\n\n  Alex",
             "Here is the message:\n\nHi Sam, thanks for getting back to me about the proposal. Happy to talk it over on Friday.\n\nAlex"),
            ("selection starting mid-row",
             "Hi Sam, thanks for getting back to me\n  about the proposal.   ",
             "Hi Sam, thanks for getting back to me about the proposal."),
            ("short lines stay apart", "  npm install\n  npm run dev", "npm install\nnpm run dev"),
            ("list items stay apart",
             "  - one item that runs right up to edge\n  - two\n  1. three",
             "- one item that runs right up to edge\n- two\n1. three"),
            ("long token cut mid-word",
             "  https://example.com/a/very/long/path/\n  that/keeps/going",
             "https://example.com/a/very/long/path/that/keeps/going"),
            ("nested indent kept", "  if x {\n      y()\n  }", "if x {\n    y()\n}"),
        ]
        var failures = cases.compactMap { item -> String? in
            let cleaned = CopyCleanup.clean(item.raw, columns: 44)
            return cleaned == item.expected ? nil : "\(item.name): \(cleaned.debugDescription)"
        }

        // A real selection out of a 77 column Claude session: a prompt, then a three paragraph reply.
        let transcript = """
            \u{276F} did we fix the module so i can copy text here without the weird line     
              breaks                                                                   
              
            \u{23FA} No, nothing in this session touched that. The only work here was building
              the notifications module, and it has nothing to do with how copied text
              wraps.

              If you mean copying text out of the terminal in Conch and getting hard
              line breaks at the wrap points, that would be a fix in the conch repo,
              and I haven't looked at it or seen it done. If you mean somewhere else (a
              field in one of the modules, say), tell me where "here" is and I'll
              check.

              Do you want me to look at Conch's copy behaviour now?
            """
        let expected = """
            \u{276F} did we fix the module so i can copy text here without the weird line breaks

            No, nothing in this session touched that. The only work here was building the notifications module, and it has nothing to do with how copied text wraps.

            If you mean copying text out of the terminal in Conch and getting hard line breaks at the wrap points, that would be a fix in the conch repo, and I haven't looked at it or seen it done. If you mean somewhere else (a field in one of the modules, say), tell me where "here" is and I'll check.

            Do you want me to look at Conch's copy behaviour now?
            """
        let cleaned = CopyCleanup.clean(transcript, columns: 77)
        if cleaned != expected { failures.append("transcript: \(cleaned.debugDescription)") }
        return failures
    }

    private func checkLaunchCommand(directory: String) -> (Bool, String) {
        var failures: [String] = []

        let fresh = LaunchSpec.claude(directory, remoteControl: true)
        let freshArgv = LaunchCommand.claudeArgv(for: fresh, displayName: "Smoke", restoring: false) ?? []
        if !freshArgv.contains("--session-id") { failures.append("new claude lacks --session-id: \(freshArgv)") }
        if !freshArgv.contains("--remote-control=Smoke") { failures.append("new claude lacks --remote-control: \(freshArgv)") }

        // A fresh UUID has no transcript, so restoring must fall back to a new session with the same id.
        let restoredArgv = LaunchCommand.claudeArgv(for: fresh, displayName: "Smoke", restoring: true) ?? []
        if !restoredArgv.contains("--session-id") || restoredArgv.contains("--resume") {
            failures.append("restore without transcript: \(restoredArgv)")
        }

        // A name starting with "-" must stay attached, or claude reads it as an unknown option.
        let dashed = LaunchCommand.claudeArgv(for: fresh, displayName: "-wip", restoring: false) ?? []
        if !dashed.contains("--remote-control=-wip") { failures.append("dash-leading name not attached: \(dashed)") }

        let described = LaunchSpec.cloud(directory, target: "fix the login bug")
        if let argv = LaunchCommand.claudeArgv(for: described, displayName: "Smoke", restoring: true) {
            failures.append("restoring a described web session returned \(argv), expected nil")
        }

        let attachCases: [(String, Bool)] = [
            ("session_01ABC", true),
            ("https://claude.ai/code/session_01ABC", true),
            ("fix the login bug", false),
        ]
        for (target, expected) in attachCases where LaunchCommand.isCloudAttachTarget(target) != expected {
            failures.append("isCloudAttachTarget(\(target)) should be \(expected)")
        }

        return failures.isEmpty ? (true, "all launch rules hold") : (false, failures.joined(separator: "; "))
    }

    // MARK: - Helpers

    func record(_ name: String, _ ok: Bool, _ detail: String) {
        print("[smoke] \(ok ? "ok  " : "FAIL") \(name): \(detail)")
        results.record(SmokeCheck(name: name, ok: ok, detail: detail))
    }

    /// Polls `condition` on the main actor until it holds or `timeout` seconds pass.
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return true }
            if Date() >= deadline { return false }
            await pause(0.1)
        }
    }

    func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func makeTemporaryDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("conch-smoke-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// realpath, so /var and /private/var compare equal.
    private func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The path printed after the CONCH_CLAUDE_PATH= marker. The echoed command line itself has "$(" there instead.
    private func markedPath(in text: String) -> String? {
        text.components(separatedBy: "CONCH_CLAUDE_PATH=")
            .dropFirst()
            .lazy
            .compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
            .first { $0.hasPrefix("/") }
    }

    func tail(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))
    }
}

struct SmokeCheck: Codable {
    let name: String
    let ok: Bool
    let detail: String
}

/// Shared between the main actor and the timeout watchdog thread. Whichever finishes first writes and exits.
private final class SmokeResults: @unchecked Sendable {
    private struct Report: Codable {
        let passed: Bool
        let checks: [SmokeCheck]
    }

    private let lock = NSLock()
    private let path: String
    private var checks: [SmokeCheck] = []
    private var finished = false

    init(path: String) {
        self.path = path
    }

    var allPassed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !checks.isEmpty && checks.allSatisfy(\.ok)
    }

    func record(_ check: SmokeCheck) {
        lock.lock()
        defer { lock.unlock() }
        checks.append(check)
    }

    func finish(exitCode: Int32, extra: SmokeCheck?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        if let extra { checks.append(extra) }
        let report = Report(passed: exitCode == 0, checks: checks)
        lock.unlock()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(report)
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            print("[smoke] \(report.passed ? "passed" : "failed"), wrote \(path)")
        } catch {
            FileHandle.standardError.write(Data("[smoke] could not write \(path): \(error)\n".utf8))
        }
        exit(exitCode)
    }
}
