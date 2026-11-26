import Foundation

// Owner: model builder (feature/model).

extension LaunchCommand {
    /// `--model=<model>` when the session has one, on new and resumed launches alike, so a relaunch keeps the model
    /// in use rather than whatever Claude Code's default has become since. "=" keeps it one argv entry.
    static func modelArguments(for options: ClaudeOptions) -> [String] {
        let model = (options.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? [] : ["--model=\(model)"]
    }
}
