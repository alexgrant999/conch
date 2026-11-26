import Foundation

// Owner: codex builder (feature/codex).

extension SessionStore {
    /// A Codex session in `dir` (the active folder when nil). `split` adds it to the selected group.
    @discardableResult
    func newCodex(in dir: String? = nil, split: Bool = false) -> TerminalSession {
        newSession(.codex(resolvedDirectory(dir)), splitInto: split ? selectedGroupID : nil)
    }

    /// A Codex session whose first message is `prompt`. The message is cleared from the spec once it has started,
    /// so a relaunch before Codex recorded the session does not send it again.
    @discardableResult
    func newCodex(in directory: String, prompt: String, splitInto groupID: UUID?, select: Bool) -> TerminalSession {
        let session = newSession(.codex(directory, prompt: prompt), splitInto: groupID, select: select)
        session.updateSpec { $0.codex?.initialPrompt = nil }
        scheduleSave()
        return session
    }

    /// A Claude session whose first message is `prompt`, with the settings' Remote Control and model.
    @discardableResult
    func newClaude(in directory: String, prompt: String, splitInto groupID: UUID?, select: Bool) -> TerminalSession {
        var spec = newClaudeSpec(in: directory)
        spec.claude?.initialPrompt = prompt
        return newSession(spec, splitInto: groupID, select: select)
    }

    func setCodexSessionID(_ session: TerminalSession, to id: String) {
        guard session.spec.kind == .codex, session.spec.codex?.sessionID != id else { return }
        session.updateSpec { $0.codex?.sessionID = id }
        scheduleSave()
    }
}
