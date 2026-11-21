import Foundation

// Owner: context builder (feature/context).

extension LaunchCommand {
    /// Extra claude arguments that let Conch read context use for a Claude session: a settings file whose
    /// statusLine saves Claude Code's statusline JSON (see ContextStatusLine). Empty when the files could not be
    /// written, because claude will not start with a missing `--settings` file.
    static func contextArguments(for spec: LaunchSpec) -> [String] {
        guard spec.kind == .claude, ContextStatusLine.install() else { return [] }
        return ["--settings=\(ContextStatusLine.settingsURL.path)"]
    }

    /// The first message for a new Claude session (`ClaudeOptions.initialPrompt`). Only used when not resuming.
    /// "--" ends option parsing, so a prompt starting with "-", or one after a variadic option such as
    /// `--add-dir` in extraArgs, is still read as the prompt. claude 2.1 dispatches a first operand that names a
    /// subcommand even after "--" (a prompt of just "purge" would delete the project's data), so a one-word
    /// prompt gets a trailing space, which no command name matches.
    static func initialPromptArguments(for options: ClaudeOptions) -> [String] {
        let prompt = (options.initialPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return [] }
        return ["--", prompt.contains(where: \.isWhitespace) ? prompt : prompt + " "]
    }
}
