import Foundation

// Owner: codex builder (feature/codex).

extension LaunchCommand {
    /// `codex resume <id>` when Codex still has the session's file, else `codex` with the first message after `--`
    /// (so a message starting with "-" or named like a subcommand stays a message). Extra args come before either.
    static func codexArgv(for spec: LaunchSpec) -> [String] {
        let options = spec.codex ?? CodexOptions()
        if let id = options.sessionID, CodexSessions.rolloutExists(id: id) {
            return ["codex", "resume"] + options.extraArgs + [id]
        }
        var argv = ["codex"] + options.extraArgs
        let prompt = (options.initialPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { argv += ["--", prompt] }
        return argv
    }
}
