import Foundation

// Owner: model builder (feature/model).

extension SessionStore {
    /// The model new Claude sessions start with, nil for Claude Code's own default.
    var defaultClaudeModel: String? {
        settings.defaultModel.isEmpty ? nil : settings.defaultModel
    }

    /// A new Claude session's spec in `dir`: Remote Control and model from the settings.
    func newClaudeSpec(in dir: String) -> LaunchSpec {
        var spec = LaunchSpec.claude(dir, remoteControl: settings.remoteControlByDefault)
        spec.claude?.model = defaultClaudeModel
        return spec
    }

    /// Records the model a Claude session runs, so a relaunch passes it.
    func setClaudeModel(_ session: TerminalSession, to model: String) {
        guard session.spec.kind == .claude, session.spec.claude?.model != model else { return }
        // The spec is not published, and the toolbar's model menu reads it.
        session.objectWillChange.send()
        session.updateSpec { $0.claude?.model = model }
        scheduleSave()
    }

    /// Records the model Claude Code reported. A family alias chosen in Conch ("opus") stays while the reports are
    /// from that family, so the session keeps following the latest model of it.
    func followReportedModel(_ session: TerminalSession, to model: String) {
        if let stored = session.spec.claude?.model, ClaudeModels.families.contains(where: { $0.alias == stored }),
           ClaudeModels.family(of: model)?.alias == stored { return }
        setClaudeModel(session, to: model)
    }
}
