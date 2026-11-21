import Foundation

// Owner: feature/recent-conversations builder.

extension SmokeTest {
    /// Smoke checks for this feature. Record each with `record("<number> <name>", ok, detail)`.
    func checkRecentConversations(directory: String) async {
        let name = "11 recent conversations"
        let config = (directory as NSString).appendingPathComponent("claude-config")
        let previous = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        setenv("CLAUDE_CONFIG_DIR", config, 1)
        defer {
            if let previous { setenv("CLAUDE_CONFIG_DIR", previous, 1) } else { unsetenv("CLAUDE_CONFIG_DIR") }
        }

        let ids = FakeConversationIDs()
        let newerURL: URL
        do {
            newerURL = try writeFakeTranscripts(config: config, directory: directory, ids: ids)
        } catch {
            record(name, false, "could not write fake transcripts: \(error)")
            return
        }
        let promptTitle = "please review the pasted notes and summarise them for me as…"
        let renamed = "Call notes, renamed"
        var failures: [String] = []

        let started = Date()
        let first = await recentConversations()
        let buildTime = Date().timeIntervalSince(started)
        let firstReads = ConversationIndex.shared.filesReadByLastBuild
        let cachedStart = Date()
        let cached = await recentConversations()
        let cachedTime = Date().timeIntervalSince(cachedStart)

        let expected = [ids.newer, ids.promptOnly, ids.older]
        if first.map(\.sessionID) != expected {
            failures.append("order \(first.map { $0.sessionID.uuidString.prefix(8) }), expected newer, prompt only, older")
        }
        let titles = first.map(\.title)
        if titles != ["Review the call notes", promptTitle, "Login fixes"] { failures.append("titles \(titles)") }
        if first.contains(where: { $0.directory != directory }) {
            failures.append("directories \(first.map(\.directory)), expected the first cwd \(directory)")
        }
        if first.contains(where: { $0.title.count > ConversationIndex.maxTitleLength }) { failures.append("a title over 60 characters") }
        if cached != first { failures.append("cached list differs from the first build") }
        if firstReads != 7 { failures.append("first build read \(firstReads) transcripts, expected 7") }

        // Rename one conversation. Only that transcript is read again, and the new custom title wins.
        var rebuildTime: TimeInterval = 0
        var rebuildReads = -1
        do {
            let handle = try FileHandle(forWritingTo: newerURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"type\":\"custom-title\",\"customTitle\":\"\(renamed)\"}\n".utf8))
            try handle.close()
            ConversationIndex.shared.expireListCache()
            let rebuildStart = Date()
            let rebuilt = await recentConversations()
            rebuildTime = Date().timeIntervalSince(rebuildStart)
            rebuildReads = ConversationIndex.shared.filesReadByLastBuild
            if rebuilt.first?.title != renamed { failures.append("after /rename the title is \(rebuilt.first?.title ?? "nil")") }
        } catch {
            failures.append("could not append a custom title: \(error)")
        }
        if rebuildReads != 1 { failures.append("rebuild read \(rebuildReads) transcripts, expected only the renamed one") }
        let list = await recentConversations()

        let model = PaletteModel(mode: .quickOpen, store: store, projects: [])
        model.conversations = list
        let recent = model.recentConversationItems(query: "")
        let recentIDs = recent.map(\.id)
        if recentIDs != expected.map({ "conversation:\($0.uuidString)" }) { failures.append("empty query items \(recentIDs)") }
        if let item = recent.last {
            if item.title != "Login fixes" || item.hint != "↩ Resume" || item.symbol != "bubble.left"
                || !(item.detail ?? "").hasPrefix(directory.abbreviatingHome + " · ") {
                failures.append("item title \(item.title), hint \(item.hint ?? "nil"), detail \(item.detail ?? "nil")")
            }
        }
        if !model.items.contains(where: { $0.id == "conversation:\(ids.older.uuidString)" }) {
            failures.append("Quick Open items lack the conversation")
        }
        let loginHits = model.recentConversationItems(query: "login").map(\.id)
        if loginHits.first != "conversation:\(ids.older.uuidString)" { failures.append("query \"login\" gave \(loginHits)") }
        let folderHits = model.recentConversationItems(query: directory.lastPathComponentOrSelf).count
        if folderHits != 3 { failures.append("folder name query matched \(folderHits) of 3") }
        let misses = model.recentConversationItems(query: "zqxjv").count
        if misses != 0 { failures.append("nonsense query matched \(misses)") }

        // A conversation already open in Conch (here through the context monitor's id) is left out.
        if let session = store.allSessions.first {
            let saved = session.context
            session.context = ContextUsage(usedPercent: 1, windowTokens: nil, claudeSessionID: ids.older, updated: Date())
            let remaining = model.recentConversationItems(query: "").map(\.id)
            session.context = saved
            let expectedRemaining = [ids.newer, ids.promptOnly].map { "conversation:\($0.uuidString)" }
            if remaining != expectedRemaining { failures.append("open conversation not left out: \(remaining)") }
        } else {
            failures.append("no open session to test leaving out open conversations")
        }

        let timing = String(format: "build %.1f ms (%d read), cached %.1f ms, rebuild after rename %.1f ms (%d read)",
                            buildTime * 1000, firstReads, cachedTime * 1000, rebuildTime * 1000, rebuildReads)
        record(name, failures.isEmpty, failures.isEmpty
               ? "3 of 9 transcripts listed newest first (custom title, latest AI title from the wide tail, 60-char prompt title; missing folder, headless, commands-only, subagent, stray and duplicate left out), detail \"\(recent.last?.detail ?? "")\", \(timing)"
               : failures.joined(separator: "; "))
    }

    private func recentConversations() async -> [ConversationSummary] {
        await withCheckedContinuation { continuation in
            ConversationIndex.shared.refreshIfNeeded { continuation.resume(returning: $0) }
        }
    }

    private struct FakeConversationIDs {
        let older = UUID()
        let newer = UUID()
        let promptOnly = UUID()
        let missingFolder = UUID()
        let headless = UUID()
        let commandsOnly = UUID()
        let subagent = UUID()
    }

    /// Nine transcripts: three real conversations, plus one whose folder is gone, a headless run, a commands-only
    /// session, a subagent transcript in a subfolder, a file not named by a session id, and a stale copy of one
    /// conversation in another folder. Returns the newer conversation's transcript.
    private func writeFakeTranscripts(config: String, directory: String, ids: FakeConversationIDs) throws -> URL {
        let fileManager = FileManager.default
        let projects = URL(fileURLWithPath: config, isDirectory: true).appendingPathComponent("projects", isDirectory: true)
        let project = projects.appendingPathComponent(LaunchCommand.encodeProjectPath(directory), isDirectory: true)
        let moved = projects.appendingPathComponent("-old-location", isDirectory: true)
        let subagents = project.appendingPathComponent(ids.newer.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        for folder in [project, moved, subagents] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        func line(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), as: UTF8.self)
        }
        func user(_ content: Any, cwd: String = directory, _ extra: [String: Any] = [:]) -> [String: Any] {
            var object: [String: Any] = ["type": "user", "message": ["role": "user", "content": content], "cwd": cwd,
                                         "entrypoint": "cli", "isSidechain": false, "uuid": UUID().uuidString]
            object.merge(extra) { _, new in new }
            return object
        }
        func toolOutput(_ bytes: Int) -> [String: Any] {
            user([["type": "tool_result", "tool_use_id": "toolu_big", "content": String(repeating: "x", count: bytes)]])
        }
        let human: [String: Any] = ["origin": ["kind": "human"], "promptSource": "typed"]
        let caveat = user("<local-command-caveat>Caveat: the command below was run directly.</local-command-caveat>", ["isMeta": true])
        let image: [String: Any] = ["type": "image", "source": ["type": "base64", "media_type": "image/png",
                                                                "data": String(repeating: "A", count: 300_000)]]

        func write(_ objects: [[String: Any]], to url: URL, age: TimeInterval, trailingNewline: Bool = true) throws {
            let text = try objects.map(line).joined(separator: "\n") + (trailingNewline ? "\n" : "")
            try text.write(to: url, atomically: false, encoding: .utf8)
            try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        func transcript(_ id: UUID, in folder: URL) -> URL {
            folder.appendingPathComponent(id.uuidString.lowercased() + ".jsonl")
        }

        // The latest /rename wins over a later AI title.
        try write([
            ["type": "mode", "mode": "normal"],
            caveat,
            user("<command-name>/clear</command-name>\n<command-message>clear</command-message>"),
            user("<local-command-stdout></local-command-stdout>"),
            user("  fix the   login\tbug\nand then the logout one ", human),
            ["type": "custom-title", "customTitle": "Old name"],
            ["type": "ai-title", "aiTitle": "Fixing the login bug"],
            ["type": "custom-title", "customTitle": "Login fixes"],
            ["type": "ai-title", "aiTitle": "Login bug fix summary"],
        ], to: transcript(ids.older, in: project), age: 3 * 3600)

        // Noise before the prompt, then an AI title that the last 128 KB misses, so only the wide tail read finds it.
        let later = (directory as NSString).appendingPathComponent("later")
        let newerURL = transcript(ids.newer, in: project)
        try write([
            ["type": "attachment", "attachment": ["type": "hook_success", "content": "context"], "cwd": directory],
            user("Base directory for this skill: /tmp/skill", cwd: later, ["isMeta": true]),
            user("Another Claude session sent a message:\n<teammate-message teammate_id=\"qa\">done</teammate-message>", cwd: later),
            user("<task-notification>\n<task-id>abc</task-id>\n</task-notification>", cwd: later, ["origin": ["kind": "task-notification"]]),
            user([["type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"]], cwd: later),
            user([image], cwd: later, human),
            user([["type": "text", "text": "[Image #1]"]], cwd: later, human),
            user("check the notes from the call", cwd: later, human),
            ["type": "ai-title", "aiTitle": "First summary"],
            toolOutput(300_000),
            ["type": "ai-title", "aiTitle": "Review the call notes"],
            toolOutput(200_000),
        ], to: newerURL, age: 3600)

        // No title lines, a paste and a 300 KB screenshot in the prompt (the line ends past 256 KB), and no final
        // newline, so the prompt is only read because the file ended.
        try write([
            ["type": "attachment", "attachment": ["type": "hook_success", "content": "context"], "cwd": directory],
            user([["type": "text", "text": "[Image #2] <pasted_content id=\"ab12\">\nnotes from the call\n</pasted_content>\n"
                    + "please review the pasted notes and summarise them for me as a short list of the decisions we made"],
                  image], human),
        ], to: transcript(ids.promptOnly, in: project), age: 2 * 3600, trailingNewline: false)

        let gone = (directory as NSString).appendingPathComponent("moved-away")
        try write([user("work in a folder that was moved", cwd: gone, human), ["type": "ai-title", "aiTitle": "Moved folder"]],
                  to: transcript(ids.missingFolder, in: project), age: 300)
        try write([user("You are refreshing the vault. Work without asking questions.", ["entrypoint": "sdk-cli", "promptSource": "sdk"])],
                  to: transcript(ids.headless, in: project), age: 600)
        try write([caveat, user("<command-name>/exit</command-name>"), user("<local-command-stdout>See ya!</local-command-stdout>")],
                  to: transcript(ids.commandsOnly, in: project), age: 1200)
        try write([user("subagent task that must not be listed", human)], to: transcript(ids.subagent, in: subagents), age: 60)
        try write([user("a file not named by a session id", human)], to: project.appendingPathComponent("notes.jsonl"), age: 60)
        try write([user("stale copy from before a folder move", human)], to: transcript(ids.older, in: moved), age: 5 * 3600)
        return newerURL
    }
}
