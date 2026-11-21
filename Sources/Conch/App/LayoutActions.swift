import AppKit

// Owner: layouts builder (feature/layouts).

/// Startup command and project layout flows, shared by the Session menu and the palette.
@MainActor
enum LayoutActions {
    private static var store: SessionStore { SessionStore.shared }

    /// "playday layout"
    static func title(of layout: ProjectLayout) -> String {
        "\(layout.name) layout"
    }

    /// One label per pane, for example "Claude, npm run dev".
    static func summary(of panes: [LayoutPane]) -> String {
        panes.map { pane in
            let command = pane.spec.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if pane.spec.kind == .shell, !command.isEmpty { return command }
            return pane.customName ?? (pane.spec.kind == .claude ? "Claude" : "Terminal")
        }.joined(separator: ", ")
    }

    /// True when the group has a pane a layout keeps (anything but a web session).
    static func canSaveLayout(_ group: SessionGroup) -> Bool {
        group.sessions.contains { $0.spec.kind != .cloud }
    }

    // MARK: Startup command

    /// Alert with the current command. Save stores it for the next launch, Save and Run also types it into the
    /// pane now when the shell is at its prompt. An empty field clears it.
    static func editStartupCommand(for session: TerminalSession) {
        guard session.spec.kind == .shell else { return }
        AppActions.showMainWindow()
        session.refreshProcessInfo()
        let folder = startupFolder(for: session)
        let busy = session.hasRunningChild ? (session.foregroundProcess ?? "a process") : nil

        let field = NSTextField(string: session.spec.command ?? "")
        field.placeholderString = "npm run dev"
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.frame = NSRect(x: 0, y: 0, width: 320, height: field.intrinsicContentSize.height)

        let alert = NSAlert()
        // A shell's title is often a long user@host:path, so only a name the user chose goes in the heading.
        alert.messageText = session.customName.map { "Startup Command for “\($0)”" } ?? "Startup Command"
        var info = "Runs in \(folder.abbreviatingHome) every time Conch reopens, then leaves you at a shell prompt. "
            + "Leave it empty to clear it."
        if let busy {
            info += "\n\nSave and Run is unavailable while \(busy) is running."
        }
        alert.informativeText = info
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Save and Run").isEnabled = busy == nil
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let sessionID = session.id
        present(alert) { response in
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn,
                  let live = store.session(withID: sessionID) else { return }
            guard let command = applyStartupCommand(field.stringValue, to: live),
                  response == .alertSecondButtonReturn, !live.activity.isExited, !live.hasRunningChild else { return }
            // Run it where the next launch will, which differs from the prompt's folder only when an existing
            // command's folder was kept.
            live.refreshProcessInfo()
            let here = ProcessInspector.physicalPath(live.currentDirectory)
            let typed = here == ProcessInspector.physicalPath(live.spec.cwd)
                ? command : "cd \(LaunchCommand.shellQuote(live.spec.cwd)) && \(command)"
            store.select(live)
            live.send(text: typed + "\r")
        }
    }

    /// Stores the startup command (empty clears it), schedules a save and returns what was stored. Setting one
    /// also sets spec.cwd to `startupFolder(for:)`, because the command runs there on every launch, not wherever
    /// the shell was last left.
    @discardableResult
    static func applyStartupCommand(_ text: String, to session: TerminalSession) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = trimmed.isEmpty ? nil : trimmed
        let folder = startupFolder(for: session)
        session.updateSpec { spec in
            spec.command = command
            if command != nil { spec.cwd = folder }
        }
        store.scheduleSave()
        return command
    }

    /// Where a startup command runs: the shell's live folder, where the user would type it. A pane that already
    /// has a command keeps its folder instead, because the shell may sit wherever that command cd'd to.
    static func startupFolder(for session: TerminalSession) -> String {
        let existing = session.spec.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard existing.isEmpty else { return session.spec.cwd }
        session.refreshProcessInfo()
        return layoutIsDirectory(session.currentDirectory) ? session.currentDirectory : session.spec.cwd
    }

    // MARK: Layouts

    /// Saves the selected group as its project's layout, confirming before it replaces a saved one.
    static func saveLayoutForSelectedGroup() {
        guard let group = store.selectedGroup else { return }
        guard let layout = store.projectLayout(for: group) else {
            AppActions.showError("Nothing to Save",
                                 detail: "Layouts keep Claude and terminal panes. Web sessions are not saved.")
            return
        }
        let layoutTitle = title(of: layout)
        let panes = summary(of: layout.panes)

        guard let existing = LayoutStore.shared.layout(forRoot: layout.root) else {
            LayoutStore.shared.save(layout)
            let alert = NSAlert()
            alert.messageText = "Saved the \(layoutTitle)"
            alert.informativeText = "Panes: \(panes).\n\nTo open them together in a new tab, press ⌘P and choose “\(layoutTitle)”."
            alert.addButton(withTitle: "OK")
            present(alert) { _ in }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Replace the \(layoutTitle)?"
        alert.informativeText = "Saved panes: \(summary(of: existing.panes)).\nNew panes: \(panes)."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            var replacement = layout
            replacement.id = existing.id
            LayoutStore.shared.save(replacement)
        }
    }

    static func open(_ layout: ProjectLayout) {
        AppActions.showMainWindow()
        guard store.openLayout(layout).isEmpty else { return }
        AppActions.showError("Could Not Open the \(title(of: layout))",
                             detail: "\(layout.root.abbreviatingHome) no longer exists.")
    }

    static func confirmDelete(_ layout: ProjectLayout) {
        AppActions.showMainWindow()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the \(title(of: layout))?"
        alert.informativeText = "Panes: \(summary(of: layout.panes)). Open sessions are not affected."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            if response == .alertFirstButtonReturn {
                LayoutStore.shared.delete(id: layout.id)
            }
        }
    }

    /// As a sheet on the main window when it is showing, else app-modal. Beeps when a sheet is already up.
    private static func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window = AppActions.mainWindow, window.isVisible, !window.isMiniaturized else {
            completion(alert.runModal())
            return
        }
        guard window.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }
}
