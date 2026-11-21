import Foundation

// Owner: context builder (feature/context).

extension SessionStore {
    /// Points a Claude session at the conversation Claude Code reports, which changes after /clear or /resume, so
    /// a relaunch resumes the conversation in use rather than the one it started with.
    func followClaudeConversation(_ session: TerminalSession, to conversationID: UUID) {
        guard session.spec.kind == .claude, let current = session.spec.claude?.sessionID,
              current != conversationID else { return }
        session.updateSpec { $0.claude?.sessionID = conversationID }
        scheduleSave()
    }

    /// A new Claude session in `directory` whose first message is `prompt`, with the same Remote Control setting
    /// and extra arguments as `source`. Selected only when `source` is still the active session.
    @discardableResult
    func newClaude(continuing source: TerminalSession, in directory: String, prompt: String) -> TerminalSession {
        var spec = LaunchSpec.claude(directory, remoteControl: source.spec.claude?.remoteControl ?? settings.remoteControlByDefault)
        spec.claude?.extraArgs = source.spec.claude?.extraArgs ?? []
        spec.claude?.initialPrompt = prompt
        return newSession(spec, select: activeSession === source)
    }
}
