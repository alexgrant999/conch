import AppKit

// Owner: model builder (feature/model). Shared by the toolbar menu, the Session menu and the palette.

@MainActor
enum ModelActions {
    /// True when the session runs this entry: the same alias for a Latest entry, else the same model (a dated or 1M
    /// context id counts as its model).
    static func isCurrent(_ choice: ClaudeModelChoice, for session: TerminalSession) -> Bool {
        guard let stored = session.spec.claude?.model else { return false }
        if choice.isLatest { return stored == choice.model }
        return ClaudeModels.choice(model: stored)?.model == choice.model
    }

    /// "Opus 5.5" as Claude Code names it. Right after a switch, before Claude Code reports, the chosen entry's name.
    /// "Model" when nothing is known yet.
    static func label(for session: TerminalSession) -> String {
        if let name = session.modelName { return name }
        guard let stored = session.spec.claude?.model else { return "Model" }
        return ClaudeModels.choice(model: stored)?.name ?? stored
    }

    static func choose(_ choice: ClaudeModelChoice, for session: TerminalSession) {
        choose(model: choice.model, for: session)
    }

    /// Types `/model <model>` at Claude's empty prompt and records it for the next launch. Claude Code also saves it
    /// as its own default for new sessions.
    static func choose(model: String, for session: TerminalSession) {
        guard ContextActions.canAct(on: session) else {
            NSSound.beep()
            Toast.show(ContextActions.busyMessage)
            return
        }
        guard ContextActions.promptIsEmpty(session) else { return }
        ContextActions.type("/model \(model)", into: session)
        SessionStore.shared.setClaudeModel(session, to: model)
        // Claude Code's report of the new model brings the name back.
        session.modelName = nil
    }

    /// Asks for any model id Claude Code accepts, for models the menus do not list.
    static func chooseOther(for session: TerminalSession) {
        let alert = NSAlert()
        alert.messageText = "Other Model"
        alert.informativeText = "Type a model id or alias that Claude Code accepts. Conch switches “\(session.displayName)” to it with /model."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "For example: claude-opus-4-1"
        field.stringValue = session.spec.claude?.model ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let sessionID = session.id
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn, let live = SessionStore.shared.session(withID: sessionID) else { return }
            let model = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ClaudeModels.isValidModel(model) else {
                NSSound.beep()
                AppActions.showError("That is not a model id",
                                     detail: "A model id is one word of letters, digits and dashes, for example claude-opus-4-1.")
                return
            }
            choose(model: model, for: live)
        }
        guard let window = AppActions.mainWindow, window.isVisible, window.attachedSheet == nil else {
            finish(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: finish)
    }
}
