import Combine
import Foundation

// Owner: feature/context builder.

extension SmokeTest {
    /// Smoke checks for this feature. Record each with `record("<number> <name>", ok, detail)`.
    /// Never runs claude: the wrapper is fed a fake statusline JSON and the monitor watches a fake context file.
    func checkContext(directory: String) async {
        var failures = checkContextLaunchArguments(directory: directory)
        failures += checkStatusLineWrapper(directory: directory)
        failures += await checkContextMonitor(directory: directory)
        failures += await checkChoiceDetection(directory: directory)
        failures += await checkPromptDraft(directory: directory)
        failures += checkGitExclude(directory: directory)
        if ContextLevel(59.9) != .normal || ContextLevel(60) != .filling || ContextLevel(80) != .full {
            failures.append("context levels do not split at 60 and 80")
        }
        record("15 context", failures.isEmpty,
               failures.isEmpty ? "settings flag, wrapper chain, project lookup, monitor, prompt guard and git exclude all hold"
                   : failures.joined(separator: "; "))
    }

    private func checkContextLaunchArguments(directory: String) -> [String] {
        var failures: [String] = []
        var spec = LaunchSpec.claude(directory, remoteControl: false)
        let flag = "--settings=\(ContextStatusLine.settingsURL.path)"
        let argv = LaunchCommand.claudeArgv(for: spec, displayName: "Smoke", restoring: false) ?? []
        if !argv.contains(flag) { failures.append("claude argv lacks \(flag): \(argv)") }
        if !LaunchCommand.contextArguments(for: .shell(directory)).isEmpty { failures.append("shell got context arguments") }

        let command = (try? Data(contentsOf: ContextStatusLine.settingsURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["statusLine"] as? [String: Any] }?["command"] as? String
        if command != LaunchCommand.shellQuote(ContextStatusLine.wrapperURL.path) {
            failures.append("settings statusLine command is \(command ?? "missing")")
        }

        spec.claude?.initialPrompt = "-v keeps its dash"
        let prompted = LaunchCommand.claudeArgv(for: spec, displayName: "Smoke", restoring: false) ?? []
        if Array(prompted.suffix(2)) != ["--", "-v keeps its dash"] { failures.append("initial prompt argv: \(prompted)") }
        if LaunchCommand.initialPromptArguments(for: ClaudeOptions(initialPrompt: "purge")) != ["--", "purge "] {
            failures.append("one-word prompt is not padded")
        }
        if !LaunchCommand.initialPromptArguments(for: ClaudeOptions(initialPrompt: "  ")).isEmpty {
            failures.append("blank prompt produced arguments")
        }
        return failures
    }

    /// The wrapper saves its input under CONCH_SESSION_ID and pipes it to the user's statusLine command, found
    /// through CLAUDE_CONFIG_DIR, or the project's under CLAUDE_PROJECT_DIR. A statusLine in a folder Claude merely
    /// cd'd into (the wrapper's cwd) must never run. The variables are set for the wrapper process only.
    private func checkStatusLineWrapper(directory: String) -> [String] {
        var failures: [String] = []
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: directory).appendingPathComponent("context-wrapper", isDirectory: true)
        let config = root.appendingPathComponent("claude config", isDirectory: true)
        let bare = root.appendingPathComponent("bare config", isDirectory: true)
        let project = root.appendingPathComponent("project dir", isDirectory: true)
        let cloned = project.appendingPathComponent("cloned repo", isDirectory: true)
        let marker = root.appendingPathComponent("cloned statusline ran")
        func install(_ body: String, as name: String, for folder: URL, settings: URL) throws {
            let script = folder.appendingPathComponent(name)
            try fileManager.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let object = ["statusLine": ["type": "command", "command": LaunchCommand.shellQuote(script.path)]]
            try JSONSerialization.data(withJSONObject: object).write(to: settings)
        }
        do {
            try fileManager.createDirectory(at: config, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: bare, withIntermediateDirectories: true)
            try install("read -r line\nprintf 'FAKE %s' \"$line\"", as: "fake statusline.sh", for: config,
                        settings: config.appendingPathComponent("settings.json"))
            try install("read -r line\nprintf 'PROJECT %s' \"$line\"", as: "project statusline.sh", for: root,
                        settings: project.appendingPathComponent(".claude/settings.json"))
            try install("touch \(LaunchCommand.shellQuote(marker.path))\nprintf CLONED", as: "cloned statusline.sh", for: root,
                        settings: cloned.appendingPathComponent(".claude/settings.json"))
        } catch {
            return ["could not set up a fake config: \(error)"]
        }

        let sessionID = UUID().uuidString.lowercased()
        let input = #"{"session_id":"\#(UUID().uuidString.lowercased())","context_window":{"used_percentage":42.5}}"#
        let saved = ContextStatusLine.contextDirectory.appendingPathComponent("\(sessionID).json")

        let chained = runWrapper(input: input, sessionID: sessionID, configDirectory: config, in: directory)
        if chained != "FAKE \(input)" { failures.append("wrapper printed \(chained.map { "\"\($0)\"" } ?? "nothing (timed out)"), expected the fake statusline") }
        if (try? String(contentsOf: saved, encoding: .utf8)) != input { failures.append("wrapper did not save the JSON to \(saved.path)") }
        try? fileManager.removeItem(at: saved)

        let silent = runWrapper(input: input, sessionID: sessionID, configDirectory: bare, in: directory)
        if silent != "" { failures.append("wrapper without a user statusline printed \(silent.map { "\"\($0)\"" } ?? "nothing (timed out)")") }
        if !fileManager.fileExists(atPath: saved.path) { failures.append("wrapper without a user statusline did not save the JSON") }
        try? fileManager.removeItem(at: saved)

        let fromProject = runWrapper(input: input, sessionID: sessionID, configDirectory: config, in: cloned.path,
                                     projectDirectory: project.path)
        if fromProject != "PROJECT \(input)" {
            failures.append("with CLAUDE_PROJECT_DIR the wrapper printed \(fromProject.map { "\"\($0)\"" } ?? "nothing (timed out)"), expected the project statusline")
        }
        let withoutProject = runWrapper(input: input, sessionID: sessionID, configDirectory: config, in: cloned.path)
        if withoutProject != "FAKE \(input)" {
            failures.append("without CLAUDE_PROJECT_DIR the wrapper printed \(withoutProject.map { "\"\($0)\"" } ?? "nothing (timed out)"), expected the user statusline")
        }
        if fileManager.fileExists(atPath: marker.path) { failures.append("the wrapper ran a statusLine from its working directory") }
        try? fileManager.removeItem(at: saved)

        let unsafe = runWrapper(input: input, sessionID: "../escape", configDirectory: bare, in: directory)
        if unsafe != "" || fileManager.fileExists(atPath: ContextStatusLine.supportDirectory.appendingPathComponent("escape.json").path) {
            failures.append("wrapper accepted a session id with a path in it")
        }
        try? fileManager.removeItem(at: root)
        return failures
    }

    /// Screens laid out the way Claude Code 2.1 draws them, fed into a session that is never started.
    private func checkChoiceDetection(directory: String) async -> [String] {
        var failures: [String] = []
        let session = TerminalSession(spec: .claude(directory, remoteControl: false))
        let rule = String(repeating: "─", count: 60)
        // A past message that looks like a list item sits above the input box and must not count.
        session.view.feed(text: "❯ 1. an earlier message\r\n\r\n\(rule)\r\n❯ half typed\r\n\(rule)\r\n  [Opus] ctx: 10%\r\n")
        await pause(0.2)
        if ContextActions.isShowingChoice(session) { failures.append("the idle input box was taken for a choice") }
        session.view.feed(text: "\(rule)\r\n  Do you want to proceed?\r\n  ❯ 1. Yes\r\n    2. No\r\n")
        if !(await waitUntil(2, { ContextActions.isShowingChoice(session) })) {
            failures.append("a permission prompt was not recognised")
        }
        return failures
    }

    /// Input boxes as Claude Code 2.1 draws them: the placeholder is dim (SGR 2), typed text is not, and
    /// Shift+Return adds a row. Each screen goes into its own session, which is never started.
    private func checkPromptDraft(directory: String) async -> [String] {
        let rule = String(repeating: "─", count: 60)
        let screens: [(String, String, ContextActions.PromptState)] = [
            ("empty prompt with placeholder", "\(rule)\r\n❯\u{A0}\u{1B}[2mTry \"fix lint errors\"\u{1B}[22m\r\n\(rule)\r\n  footer\r\n", .empty),
            ("bare empty prompt", "\(rule)\r\n❯\r\n\(rule)\r\n", .empty),
            ("one-line draft", "\(rule)\r\n❯\u{A0}half typed\r\n\(rule)\r\n", .draft),
            ("two-line draft", "\(rule)\r\n❯\u{A0}line one\r\n  line two\r\n\(rule)\r\n", .draft),
            ("bash mode", "\(rule)\r\n! ls\r\n\(rule)\r\n", .draft),
            ("no input box", "plain shell output\r\n$ \r\n", .unknown),
        ]
        var sessions: [(String, TerminalSession, ContextActions.PromptState)] = []
        for (name, text, expected) in screens {
            let session = TerminalSession(spec: .claude(directory, remoteControl: false))
            session.view.feed(text: text)
            sessions.append((name, session, expected))
        }
        var wrong: [String] = []
        let settled = await waitUntil(2) {
            wrong = sessions.compactMap { name, session, expected in
                let state = ContextActions.promptState(session)
                return state == expected ? nil : "\(name) read as \(state)"
            }
            return wrong.isEmpty
        }
        return settled ? [] : ["prompt guard: " + wrong.joined(separator: ", ")]
    }

    /// Against a real repository and a linked worktree: the note's path lands once in the common info/exclude,
    /// existing lines stay, and git then ignores the note in both work trees.
    private func checkGitExclude(directory: String) -> [String] {
        var failures: [String] = []
        let root = URL(fileURLWithPath: directory).appendingPathComponent("context-exclude", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let worktree = root.appendingPathComponent("repo-wt", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        } catch {
            return ["could not create \(repo.path): \(error)"]
        }
        for args in [["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "init"],
                     ["worktree", "add", "-q", "-b", "context-smoke", worktree.path]] {
            let result = contextGit(args, in: repo.path)
            if result.status != 0 { return ["git \(args.joined(separator: " ")) failed: \(tail(result.output))"] }
        }
        let gitDirectory = contextGit(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: worktree.path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        let exclude = URL(fileURLWithPath: gitDirectory).appendingPathComponent("info/exclude")
        try? FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = ((try? String(contentsOf: exclude, encoding: .utf8)) ?? "") + "keep-me"
        try? Data(before.utf8).write(to: exclude)

        let note = ContextActions.handoffNote
        if !ContextGitExclude.add(worktree.appendingPathComponent(note)) { failures.append("exclude from the worktree failed") }
        _ = ContextGitExclude.add(repo.appendingPathComponent(note))
        _ = ContextGitExclude.add(repo.appendingPathComponent("web/" + note))
        let after = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        if !after.hasPrefix(before + "\n") { failures.append("existing exclude lines were not kept") }
        let lines = after.split(separator: "\n").map(String.init)
        if lines.filter({ $0 == note }).count != 1 { failures.append("\(note) listed \(lines.filter { $0 == note }.count) times") }
        if !lines.contains("web/" + note) { failures.append("a note in a subfolder was not listed by its path") }
        for (tree, path) in [(worktree, note), (repo, note), (repo, "web/" + note)]
            where contextGit(["check-ignore", "-q", path], in: tree.path).status != 0 {
            failures.append("git does not ignore \(path) in \(tree.lastPathComponent)")
        }
        if ContextGitExclude.add(root.appendingPathComponent(note)) { failures.append("a folder outside git got an exclude") }
        return failures
    }

    /// git with no system or global config, so a user's hooks or signing settings cannot break the throwaway repo.
    private func contextGit(_ args: [String], in dir: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Conch Smoke", "-c", "user.email=smoke@conch.invalid", "-C", dir] + args
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                               "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "LANG": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The wrapper's stdout, or nil when it did not finish within 5 s.
    private func runWrapper(input: String, sessionID: String, configDirectory: URL, in directory: String,
                            projectDirectory: String? = nil) -> String? {
        let process = Process()
        process.executableURL = ContextStatusLine.wrapperURL
        var environment = ProcessInfo.processInfo.environment
        environment["CONCH_SESSION_ID"] = sessionID
        environment["CLAUDE_CONFIG_DIR"] = configDirectory.path
        environment["CLAUDE_PROJECT_DIR"] = projectDirectory
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        guard !process.isRunning else {
            process.terminate()
            return nil
        }
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// A Claude session that is never started (so no claude runs), watched through a real folder event source.
    private func checkContextMonitor(directory: String) async -> [String] {
        var failures: [String] = []
        let folder = URL(fileURLWithPath: directory).appendingPathComponent("context-monitor", isDirectory: true)
        let session = TerminalSession(spec: .claude(directory, remoteControl: false))
        let monitor = ContextMonitor(directory: folder, sessions: { [session] },
                                     sessionsChanged: Empty().eraseToAnyPublisher())
        monitor.start()
        defer { monitor.stop() }

        let file = folder.appendingPathComponent("\(session.id.uuidString.lowercased()).json")
        func report(_ conversation: UUID?, percent: String) {
            let id = conversation.map { #""\#($0.uuidString.lowercased())""# } ?? "null"
            let json = #"{"session_id":\#(id),"workspace":{"project_dir":"\#(directory)"},"#
                + #""context_window":{"used_percentage":\#(percent),"context_window_size":200000}}"#
            try? Data(json.utf8).write(to: file, options: .atomic)
        }

        let launchID = session.spec.claude?.sessionID
        report(launchID, percent: "64.5")
        if await waitUntil(3, { session.context?.usedPercent == 64.5 }) {
            if session.context?.windowTokens != 200_000 { failures.append("window size \(String(describing: session.context?.windowTokens))") }
            if session.spec.claude?.sessionID != launchID { failures.append("spec changed for the same conversation") }
            if monitor.directory(for: session) != directory { failures.append("project folder not recorded") }
        } else {
            failures.append("monitor did not map the file to the session (context \(String(describing: session.context)))")
        }

        // After a /clear from Conch, a late report of the old conversation must not bring its reading back.
        monitor.noteCleared(session)
        report(launchID, percent: "64.5")
        await pause(0.6)
        if session.context != nil { failures.append("stale report after clear restored the reading") }

        let cleared = UUID()
        report(cleared, percent: "3.5")
        if await waitUntil(3, { session.spec.claude?.sessionID == cleared }) {
            if session.context?.usedPercent != 3.5 { failures.append("new conversation reading \(String(describing: session.context))") }
        } else {
            failures.append("spec did not follow the new conversation (still \(String(describing: session.spec.claude?.sessionID)))")
        }

        report(cleared, percent: "null")
        if !(await waitUntil(3, { session.context == nil })) { failures.append("a null percentage left a reading") }

        let orphan = folder.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
        try? Data("{}".utf8).write(to: orphan)
        if !(await waitUntil(3, { !FileManager.default.fileExists(atPath: orphan.path) })) {
            failures.append("file of an unknown session was not removed")
        }
        try? FileManager.default.removeItem(at: folder)
        return failures
    }
}
