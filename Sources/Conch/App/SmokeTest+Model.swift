import Combine
import Foundation

// Owner: model builder (feature/model).

extension SmokeTest {
    /// Smoke check 20. Never runs claude: launch arguments are built, not run, and the monitor reads a fake report.
    func checkModel(directory: String) async {
        var failures: [String] = []

        // Launch: --model=<model> on new and resumed launches alike, nothing without a model or for a shell.
        var spec = LaunchSpec.claude(directory, remoteControl: false)
        if (LaunchCommand.claudeArgv(for: spec, displayName: "Smoke", restoring: false) ?? []).contains(where: { $0.hasPrefix("--model") }) {
            failures.append("a session without a model got --model")
        }
        spec.claude?.model = "opus"
        for restoring in [false, true] {
            let argv = LaunchCommand.claudeArgv(for: spec, displayName: "Smoke", restoring: restoring) ?? []
            if !argv.contains("--model=opus") { failures.append("argv lacks --model=opus (restoring \(restoring)): \(argv)") }
        }
        if !LaunchCommand.modelArguments(for: ClaudeOptions(model: "  ")).isEmpty { failures.append("a blank model got --model") }

        // State written before this feature has no model key and must still load.
        let old = #"{"sessionID":"\#(UUID().uuidString)","remoteControl":true,"extraArgs":[]}"#
        if let decoded = try? JSONDecoder().decode(ClaudeOptions.self, from: Data(old.utf8)) {
            if decoded.model != nil { failures.append("old options decoded with model \(decoded.model ?? "")") }
        } else {
            failures.append("options without a model key did not decode")
        }

        // Menu entries: aliases and ids exactly, dated and 1M context ids as their model, never a longer id by prefix.
        let entries: [(String, String?)] = [("opus", "opus"), ("claude-opus-5-5", "claude-opus-5-5"),
                                            ("claude-opus-5", "claude-opus-5"), ("claude-sonnet-5-5[1m]", "claude-sonnet-5-5"),
                                            ("claude-sonnet-4-5-20250929", "claude-sonnet-4-5"), ("claude-opus-4-1", nil),
                                            ("claude-opus-5-55", nil), ("gpt-5", nil), ("", nil)]
        for (model, entry) in entries where ClaudeModels.choice(model: model)?.model != entry {
            failures.append("\(model) is the entry \(ClaudeModels.choice(model: model)?.model ?? "none"), expected \(entry ?? "none")")
        }
        let families: [(String, String?)] = [("claude-opus-4-8", "opus"), ("Fable 5.2", "fable"), ("haiku", "haiku"), ("gpt-5", nil)]
        for (model, alias) in families where ClaudeModels.family(of: model)?.alias != alias {
            failures.append("\(model) is in family \(ClaudeModels.family(of: model)?.alias ?? "none"), expected \(alias ?? "none")")
        }
        if Set(ClaudeModels.all.map(\.model)).count != ClaudeModels.all.count { failures.append("a model is listed twice") }
        for text in ["claude-opus-4-1", "opus[1m]"] where !ClaudeModels.isValidModel(text) { failures.append("\(text) was refused") }
        for text in ["", "two words", "-p", "opus; rm"] where ClaudeModels.isValidModel(text) { failures.append("\(text) was accepted") }

        // New sessions take the setting, and "" leaves the model to Claude Code.
        let settings = store.settings
        settings.defaultModel = "claude-opus-4-8"
        if store.newClaudeSpec(in: directory).claude?.model != "claude-opus-4-8" { failures.append("the default model setting was not applied") }
        settings.defaultModel = ""
        if store.newClaudeSpec(in: directory).claude?.model != nil { failures.append("Claude Code's default still set a model") }

        failures += await checkModelFollowing(directory: directory)

        let inToolbar = AppActions.mainWindow?.toolbar?.items.contains { $0.itemIdentifier.rawValue == "ConchModel" } ?? false
        if !inToolbar { failures.append("the model menu is not in the toolbar") }

        record("20 model", failures.isEmpty,
               failures.isEmpty ? "--model on launch and resume, old state, menu entries, default setting, following and toolbar all hold"
                   : failures.joined(separator: "; "))
    }

    /// The monitor records the reported model in the spec and its name on the session, and the label follows a
    /// switch made in Conch before Claude Code reports it.
    private func checkModelFollowing(directory: String) async -> [String] {
        var failures: [String] = []
        let folder = URL(fileURLWithPath: directory).appendingPathComponent("model-monitor", isDirectory: true)
        let session = TerminalSession(spec: .claude(directory, remoteControl: false))
        let monitor = ContextMonitor(directory: folder, sessions: { [session] },
                                     sessionsChanged: Empty().eraseToAnyPublisher())
        monitor.start()
        defer {
            monitor.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let file = folder.appendingPathComponent("\(session.id.uuidString.lowercased()).json")
        let conversation = session.spec.claude?.sessionID.uuidString.lowercased() ?? ""
        func report(_ id: String, _ name: String) {
            let json = #"{"session_id":"\#(conversation)","model":{"id":"\#(id)","display_name":"\#(name)"},"#
                + #""context_window":{"used_percentage":12,"context_window_size":200000}}"#
            try? Data(json.utf8).write(to: file, options: .atomic)
        }

        report("claude-fable-5-2", "Fable 5.2")
        guard await waitUntil(3, { session.spec.claude?.model == "claude-fable-5-2" }) else {
            return ["the reported model was not recorded (spec has \(session.spec.claude?.model ?? "none"))"]
        }
        if session.modelName != "Fable 5.2" { failures.append("model name \(session.modelName ?? "none")") }
        if ModelActions.label(for: session) != "Fable 5.2" { failures.append("label \(ModelActions.label(for: session))") }

        let fable52 = ClaudeModels.all.first { $0.model == "claude-fable-5-2" }
        if fable52.map({ !ModelActions.isCurrent($0, for: session) }) ?? true { failures.append("Fable 5.2 is not checked") }

        // Latest Opus chosen in Conch: checked at once, and kept as the alias when Opus 5.5 reports, so a relaunch
        // still follows the latest Opus.
        store.setClaudeModel(session, to: "opus")
        session.modelName = nil
        let latestOpus = ClaudeModels.families.first { $0.alias == "opus" }?.latest
        if latestOpus.map({ !ModelActions.isCurrent($0, for: session) }) ?? true || ModelActions.label(for: session) != "Latest Opus" {
            failures.append("after a switch the menu shows \(ModelActions.label(for: session))")
        }
        await pause(0.3)
        report("claude-opus-5-5", "Opus 5.5")
        if await waitUntil(3, { session.modelName == "Opus 5.5" }) {
            if session.spec.claude?.model != "opus" { failures.append("the Opus report replaced the alias with \(session.spec.claude?.model ?? "none")") }
        } else {
            failures.append("the new model's report was not applied")
        }

        // A different family reported (typed /model sonnet in the session) replaces the alias.
        await pause(0.3)
        report("claude-sonnet-4-5-20250929", "Sonnet 4.5")
        if await waitUntil(3, { session.spec.claude?.model == "claude-sonnet-4-5-20250929" }) {
            let sonnet45 = ClaudeModels.all.first { $0.model == "claude-sonnet-4-5" }
            if sonnet45.map({ !ModelActions.isCurrent($0, for: session) }) ?? true { failures.append("a dated Sonnet 4.5 id does not check Sonnet 4.5") }
        } else {
            failures.append("a report from another family did not replace the alias (spec has \(session.spec.claude?.model ?? "none"))")
        }
        return failures
    }
}
