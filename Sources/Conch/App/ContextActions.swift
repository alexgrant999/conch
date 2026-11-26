import AppKit
import SwiftTerm

// Owner: context builder (feature/context). Compact, clear and hand off, shared by the Session menu and the palette.

@MainActor
enum ContextActions {
    private static var store: SessionStore { SessionStore.shared }

    static let handoffNote = ".claude/handoff.md"
    /// Shown when Claude started a turn (or a permission prompt) between choosing an action and it running.
    static let busyMessage = "Claude is busy. Try again when it is back at its prompt"
    static let handoffPrompt = "Read .claude/handoff.md and continue from where it leaves off."

    /// The active session when the actions apply to it: a Claude session at its prompt (claude in the
    /// foreground, not busy, no hand off in progress) in a main window the user can see.
    static func actionableSession() -> TerminalSession? {
        guard let window = AppActions.mainWindow, window.isVisible, !window.isMiniaturized,
              let session = store.activeSession, canAct(on: session) else { return nil }
        return session
    }

    static func canAct(on session: TerminalSession) -> Bool {
        session.spec.kind == .claude && session.activity == .idle && isRunningClaude(session)
            && !ContextHandoff.isPending(for: session) && !isShowingChoice(session)
    }

    /// Permission prompts and pickers show a numbered list with a ❯ cursor ("❯ 1. Yes") below Claude Code's last
    /// rule line, where the input box would be. A typed command and Return would pick an option there (approve a
    /// tool call, say), so the actions wait until it is answered. Messages above the input box are not looked at.
    static func isShowingChoice(_ session: TerminalSession) -> Bool {
        guard let rows = session.view.terminalContentSnapshot(region: .history(maximumScrollbackRows: -1))?
            .rows.map(\.text) else { return false }
        let lastRule = rows.lastIndex(where: isRule)
        let below = rows[(lastRule.map { $0 + 1 } ?? max(0, rows.count - 15))...]
        return below.contains { $0.range(of: #"^[\s│]*❯\s+\d+\."#, options: .regularExpression) != nil }
    }

    enum PromptState {
        case empty
        /// Unsent text, or a box of more than one line.
        case draft
        /// No input box found on screen.
        case unknown
    }

    /// Claude Code's input box is the rows between the last two rule lines. An empty prompt is one row: "❯" and
    /// at most a dim placeholder or suggestion. Typed text is not dim, and Shift+Return adds rows.
    static func promptState(_ session: TerminalSession) -> PromptState {
        guard let rows = session.view.terminalContentSnapshot(region: .history(maximumScrollbackRows: -1))?.rows
        else { return .unknown }
        let rules = rows.indices.filter { isRule(rows[$0].text) }
        guard rules.count >= 2 else { return .unknown }
        let box = rows[(rules[rules.count - 2] + 1)..<rules[rules.count - 1]]
        guard let line = box.first else { return .unknown }
        guard box.count == 1 else { return .draft }
        // Unwritten cells hold NUL, and Claude Code puts a no-break space after "❯".
        let blank = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{0}"))
        let isBlank = { (cell: TerminalCellSnapshot) in cell.text.trimmingCharacters(in: blank).isEmpty }
        // Anything but "❯" in front (bash mode shows "!") means the prompt is not plain.
        guard let marker = line.cells.firstIndex(where: { $0.text == "❯" }),
              line.cells[..<marker].allSatisfy(isBlank) else { return .draft }
        let typed = line.cells[(marker + 1)...].contains { !isBlank($0) && !$0.attribute.style.contains(.dim) }
        return typed ? .draft : .empty
    }

    private static func isRule(_ row: String) -> Bool {
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 20 && trimmed.allSatisfy { $0 == "─" }
    }

    /// A native install shows up as "claude". An npm install runs as node, which only counts once its
    /// statusline has reported (the monitor drops the reading when the shell takes the foreground back).
    private static func isRunningClaude(_ session: TerminalSession) -> Bool {
        guard let process = session.foregroundProcess else { return false }
        return process == "claude" || session.context != nil
    }

    static func compact(_ session: TerminalSession) {
        guard promptIsEmpty(session) else { return }
        type("/compact", into: session)
    }

    static func compactWithFocus(_ session: TerminalSession) {
        guard promptIsEmpty(session) else { return }
        let alert = NSAlert()
        alert.messageText = "Compact With Focus"
        alert.informativeText = "Claude summarises the conversation so far and keeps what matters for this focus."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "For example: the checkout bug and its failing test"
        alert.accessoryView = field
        alert.addButton(withTitle: "Compact")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        present(alert, for: session) { live in
            guard promptIsEmpty(live) else { return }
            // A newline typed into Claude Code would send the message early.
            let focus = field.stringValue.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            type(focus.isEmpty ? "/compact" : "/compact \(focus)", into: live)
        }
    }

    static func clear(_ session: TerminalSession) {
        guard promptIsEmpty(session) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear the conversation in “\(session.displayName)”?"
        alert.informativeText = "Claude starts a fresh conversation in this session. The current one stays on disk, "
            + "and /resume opens it again. Compact instead to keep a summary of it."
        alert.addButton(withTitle: "Clear").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        present(alert, for: session) { live in
            guard promptIsEmpty(live) else { return }
            type("/clear", into: live)
            ContextMonitor.shared.noteCleared(live)
        }
    }

    /// Asks Claude for a handoff note in the session's project folder. When that turn ends with the note
    /// written, a new Claude session starts there and reads it. In a git repository the note is excluded first,
    /// so `git add -A` never commits it and a worktree session's exit does not ask to keep the worktree for it.
    static func handOff(_ session: TerminalSession) {
        guard promptIsEmpty(session) else { return }
        let directory = ContextMonitor.shared.directory(for: session) ?? session.spec.cwd
        let note = URL(fileURLWithPath: directory).appendingPathComponent(handoffNote)
        ContextGitExclude.add(note)
        type("Write a short handoff note to \(note.path) (overwrite it if it exists) so a new Claude session can "
            + "pick this work up cold: the goal, what is done, what is left, the key files and decisions, and any "
            + "gotchas. Then reply with one line saying it is written.", into: session)
        ContextHandoff.start(session: session, note: note, directory: directory)
    }

    // MARK: - Private

    /// Types a command at Claude Code's empty prompt. Return goes separately, because a burst of text with a CR
    /// in it can be taken for a paste.
    static func type(_ text: String, into session: TerminalSession) {
        session.send(text: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak session] in
            MainActor.assumeIsolated { session?.send(text: "\r") }
        }
    }

    /// Commands are only typed into an empty prompt. Typed after a draft they would be sent as part of it, and
    /// clearing it from outside is not reliable (Ctrl+U deletes only from the cursor back to the line start).
    static func promptIsEmpty(_ session: TerminalSession) -> Bool {
        let name = session.displayName
        switch promptState(session) {
        case .empty:
            return true
        case .draft:
            NSSound.beep()
            AppActions.showError("Clear Claude's prompt first",
                                 detail: "“\(name)” has unsent text in its prompt. Send it, or press Esc twice to clear it, then try again.")
        case .unknown:
            NSSound.beep()
            AppActions.showError("Claude's prompt is not on screen",
                                 detail: "Conch types the command into Claude Code's prompt and could not find it in “\(name)”, so it typed nothing.")
        }
        return false
    }

    /// Runs the alert as a sheet on the main window, then `confirmed` with the session if it is still there and
    /// still at its prompt.
    private static func present(_ alert: NSAlert, for session: TerminalSession,
                                confirmed: @escaping (TerminalSession) -> Void) {
        let sessionID = session.id
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn, let live = store.session(withID: sessionID) else { return }
            guard canAct(on: live) else {
                Toast.show(busyMessage)
                return
            }
            confirmed(live)
        }
        guard let window = AppActions.mainWindow, window.isVisible else {
            finish(alert.runModal())
            return
        }
        guard window.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        alert.beginSheetModal(for: window, completionHandler: finish)
    }
}

/// Waits for Claude to finish writing a handoff note, then opens the session that continues from it.
@MainActor
final class ContextHandoff {
    private static var pending: [UUID: ContextHandoff] = [:]
    private static let timeout: TimeInterval = 600
    /// Two seconds of idle at 0.5 s ticks, on top of the 1.5 s of quiet that idle already means.
    private static let settleTicks = 4
    private static let startDeadline: TimeInterval = 30

    private let sessionID: UUID
    private let note: URL
    private let directory: String
    private let requested = Date()
    private var sawBusy = false
    /// Ticks spent idle with no note and no choice on screen.
    private var idleTicks = 0
    private var timer: Timer?

    static func isPending(for session: TerminalSession) -> Bool {
        pending[session.id] != nil
    }

    static func start(session: TerminalSession, note: URL, directory: String) {
        pending[session.id]?.stop()
        let handoff = ContextHandoff(sessionID: session.id, note: note, directory: directory)
        pending[session.id] = handoff
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak handoff] _ in
            MainActor.assumeIsolated { handoff?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        handoff.timer = timer
    }

    private init(sessionID: UUID, note: URL, directory: String) {
        self.sessionID = sessionID
        self.note = note
        self.directory = directory
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if Self.pending[sessionID] === self { Self.pending[sessionID] = nil }
    }

    /// The turn is over once the session has been busy and then gone idle (or, for a turn too quick to catch as
    /// busy, a few seconds after the note was written). A permission prompt or a question picker is part of the
    /// turn, so it keeps waiting through those. Idle with neither a note nor a choice means the turn ended without
    /// one (Esc, a denied write, a question in plain text): it stops and says so instead of waiting silently.
    private func tick() {
        let store = SessionStore.shared
        guard let session = store.session(withID: sessionID), !session.activity.isExited else {
            stop()
            return
        }
        let name = session.displayName
        if Date().timeIntervalSince(requested) > Self.timeout {
            give(up: "Hand off did not finish", "Claude did not write \(note.path) within ten minutes, so no new session was opened.")
            return
        }
        if session.activity == .busy {
            sawBusy = true
            idleTicks = 0
            return
        }
        guard session.activity == .idle else { return }
        if let written = (try? FileManager.default.attributesOfItem(atPath: note.path))?[.modificationDate] as? Date,
           written >= requested.addingTimeInterval(-1), sawBusy || written.timeIntervalSinceNow < -3 {
            stop()
            store.newClaude(continuing: session, in: directory, prompt: ContextActions.handoffPrompt)
            return
        }
        if ContextActions.isShowingChoice(session) {
            idleTicks = 0
            return
        }
        idleTicks += 1
        if sawBusy, idleTicks >= Self.settleTicks {
            give(up: "Hand off stopped", "Claude finished its turn in “\(name)” without writing \(ContextActions.handoffNote), "
                + "so no new session was opened. Answer it, or run Hand Off again.")
        } else if !sawBusy, Date().timeIntervalSince(requested) > Self.startDeadline {
            give(up: "Hand off did not start", "Claude in “\(name)” did not start on the handoff note, so no new session was opened.")
        }
    }

    private func give(up message: String, _ detail: String) {
        stop()
        AppActions.showError(message, detail: detail)
    }
}
