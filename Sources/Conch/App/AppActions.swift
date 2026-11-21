import AppKit

// Owner: shell agent. UI-level actions shared by menus, the sidebar and the palette.
// Anything that needs a panel, alert or the main window lives here. Pure state changes live on SessionStore.

@MainActor
enum AppActions {
    /// Main window, nil before launch finishes.
    static var mainWindow: NSWindow? { AppDelegate.shared?.windowController?.window }

    private static var store: SessionStore { SessionStore.shared }

    static func newTerminal(split: Bool = false) {
        showMainWindow()
        store.newShell(split: split)
    }

    static func newClaude(split: Bool = false) {
        showMainWindow()
        store.newClaude(split: split)
    }

    static func newTerminal(in dir: String) {
        showMainWindow()
        store.newShell(in: dir)
    }

    static func newClaude(in dir: String) {
        showMainWindow()
        store.newClaude(in: dir)
    }

    /// NSOpenPanel for a folder, then a new Claude session there.
    static func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Claude"
        panel.message = "Choose a folder to start a Claude session in."
        panel.directoryURL = URL(fileURLWithPath: store.defaultDirectory(), isDirectory: true)

        let open: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            newClaude(in: url.path)
        }
        if let window = mainWindow, window.isVisible, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: open)
        } else {
            open(panel.runModal())
        }
    }

    /// Closes after a confirmation sheet when `session.hasRunningChild`, otherwise closes straight away.
    static func requestClose(_ session: TerminalSession) {
        guard session.hasRunningChild else {
            store.close(session)
            return
        }
        // foregroundProcess is refreshed on a timer, read it fresh so the sheet names the right program.
        session.refreshProcessInfo()
        let process = session.foregroundProcess ?? "A process"

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(session.displayName)”?"
        var info = "\(process) is still running in this session. Closing the session ends it."
        if session.spec.kind == .claude {
            info += " The conversation can be picked up again later with claude --resume."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Close").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        let sessionID = session.id
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn,
                  let live = store.session(withID: sessionID) else { return }
            store.close(live)
        }

        guard let window = mainWindow, window.isVisible else {
            finish(alert.runModal())
            return
        }
        guard window.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        alert.beginSheetModal(for: window, completionHandler: finish)
    }

    /// Selects the session and puts its sidebar row into rename mode (store.renamingSessionID).
    static func beginRename(_ session: TerminalSession) {
        showMainWindow()
        AppDelegate.shared?.windowController?.revealSidebar()
        store.select(session)
        store.renamingSessionID = session.id
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path.expandingTilde)])
    }

    /// Opens the folder in VS Code (`code` CLI via the login shell when available, else `open -a "Visual Studio Code"`).
    static func openInEditor(_ path: String) {
        ConchEditorLauncher.shared.open(path.expandingTilde)
    }

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Cmd+P. Palette in quick-open mode.
    static func showQuickOpen() { showPalette(.quickOpen) }

    /// Cmd+Shift+P. Palette in commands mode.
    static func showCommandPalette() { showPalette(.commands) }

    /// Cmd+Shift+N. Palette in new-web-session mode.
    static func showNewCloudSession() { showPalette(.newCloudSession) }

    static func showSettings() {
        SettingsWindowController.shared.present()
    }

    /// Cmd+= / Cmd+- / Cmd+0. Positive or negative steps change AppSettings.fontSize by 1 within 9...32,
    /// 0 resets to 13. Then store.applyAppearanceToAll().
    static func adjustFontSize(_ delta: Int) {
        let settings = store.settings
        let next = delta == 0 ? 13 : min(32, max(9, settings.fontSize + Double(delta)))
        guard next != settings.fontSize else { return }
        settings.fontSize = next
        store.applyAppearanceToAll()
    }

    static func toggleSidebar() {
        AppDelegate.shared?.windowController?.toggleSidebar()
    }

    // MARK: - Internal helpers

    /// Shows, deminiaturizes and activates the main window.
    static func showMainWindow() {
        AppDelegate.shared?.windowController?.showMainWindow()
    }

    /// Brings Conch forward, except in a test run, which must never take focus.
    static func activateApp() {
        guard !ConchInfo.isIsolated else { return }
        NSApp.activate()
    }

    private static func showPalette(_ mode: PaletteMode) {
        showMainWindow()
        guard let window = mainWindow else { return }
        CommandPaletteController.shared.show(mode: mode, in: window)
    }

    /// Plain alert, as a sheet on the main window when it is showing.
    static func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        if let window = mainWindow, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

/// Runs editor launches off the main thread. The `code` CLI path is resolved once through the user's login shell,
/// because an app started from Finder or the Dock has a minimal PATH that rarely includes it.
private final class ConchEditorLauncher: @unchecked Sendable {
    static let shared = ConchEditorLauncher()

    private let queue = DispatchQueue(label: "com.alexgrant.conch.editor")
    /// Confined to `queue`. nil until resolved, then the CLI path or "" when there is none.
    private var codePath: String?

    func open(_ path: String) {
        queue.async { [self] in
            if codePath == nil { codePath = resolveCodeCLI() ?? "" }
            if let cli = codePath, !cli.isEmpty, run(cli, [path]) == 0 { return }
            if run("/usr/bin/open", ["-a", "Visual Studio Code", path]) == 0 { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AppActions.showError("Could not open Visual Studio Code",
                                         detail: "Install Visual Studio Code, or add its code command to your PATH from its Command Palette (Shell Command: Install 'code' command in PATH).")
                }
            }
        }
    }

    private func resolveCodeCLI() -> String? {
        let shell = LaunchCommand.userShell()
        // A file, not a pipe: a profile that hangs, or leaves a background job holding stdout, would keep a pipe
        // from ever reaching EOF and wedge every later "Open in VS Code" behind this call.
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("conch-code-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v code"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        // Profiles can print banners, so take the last line that is an executable absolute path.
        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a command to completion and returns its exit status, or -1 when it could not start.
    private func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
