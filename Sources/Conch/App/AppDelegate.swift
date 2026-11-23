import AppKit
import Carbon.HIToolbox

// Owner: shell agent.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static private(set) var shared: AppDelegate!

    var windowController: MainWindowController?

    private var store: SessionStore { SessionStore.shared }
    private var smokeTest: SmokeTest?
    private var keyMonitor: Any?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let smokeResultPath = SmokeTest.resultPath(in: CommandLine.arguments)
        if smokeResultPath != nil { SmokeTest.isolateState() }
        guard Persistence.acquireInstanceLock() else {
            Self.handOffToRunningInstance()
            return
        }

        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = buildMainMenu()
        installKeyMonitor()

        if smokeResultPath == nil { Notifier.shared.requestAuthorizationIfNeeded() }
        Notifier.shared.onActivateSession = { [weak self] id in
            guard let self, let session = self.store.session(withID: id) else { return }
            self.store.select(session)
            AppActions.showMainWindow()
        }

        let windowController = MainWindowController(store: store)
        self.windowController = windowController

        if let smokeResultPath {
            windowController.showMainWindow()
            let smokeTest = SmokeTest(resultPath: smokeResultPath, store: store)
            self.smokeTest = smokeTest
            smokeTest.start()
            return
        }

        // Nothing restored leaves the groups empty, and the container shows the empty state.
        store.restore()
        startAttentionStatusItem()
        startContextMonitor()
        windowController.showMainWindow()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard smokeTest == nil else { return .terminateNow }
        let running = store.allSessions.filter(\.hasRunningChild)
        guard !running.isEmpty else { return .terminateNow }

        running.forEach { $0.refreshProcessInfo() }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = running.count == 1
            ? "Quit Conch while a process is running?"
            : "Quit Conch while \(running.count) processes are running?"
        let lines = running.map { session in
            "• \(session.foregroundProcess ?? "a process") in \(session.displayName)"
        }
        var info = "Quitting ends:\n" + lines.joined(separator: "\n")
        if store.settings.restoreSessionsOnLaunch, running.contains(where: { $0.spec.kind == .claude }) {
            info += "\n\nClaude sessions resume on next launch."
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Another Conch already owns the saved sessions. The installed app brings that one forward. A build started
    /// from a terminal explains instead. Exits without terminate(), which would save an empty state over theirs.
    private static func handOffToRunningInstance() {
        let other = NSRunningApplication.runningApplications(withBundleIdentifier: ConchInfo.bundleID)
            .first { $0 != NSRunningApplication.current }
        if Bundle.main.bundleIdentifier == ConchInfo.bundleID, let other {
            other.activate()
        } else {
            let alert = NSAlert()
            alert.messageText = "Conch is already running"
            alert.informativeText = "Another copy of Conch is using your saved sessions. To run a second copy, "
                + "start it with CONCH_STATE_PATH set to a different file."
            alert.runModal()
        }
        exit(0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard smokeTest == nil else { return }
        store.save()
        store.terminateAll()
    }

    /// Dock click with the window hidden brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || windowController?.window?.isVisible == false {
            windowController?.showMainWindow()
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Keyboard

    /// Ctrl+Tab would otherwise reach the terminal (or move the key view loop), so it is taken before dispatch.
    /// Cmd+Shift+[ and ] are caught here too: a menu key equivalent of "]" with Shift does not match the "}"
    /// that the key event carries on a US layout.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handleKeyDown(event) }
            return handled ? nil : event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard NSApp.modalWindow == nil, windowController?.window?.attachedSheet == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])

        if event.keyCode == UInt16(kVK_Tab), modifiers == [.control] || modifiers == [.control, .shift] {
            guard let main = windowController?.window, event.window === main || event.window?.parent === main else {
                return false
            }
            store.selectAdjacentSession(modifiers.contains(.shift) ? -1 : 1)
            return true
        }

        if modifiers == [.command, .shift] {
            switch event.charactersIgnoringModifiers {
            case "}", "]":
                store.selectAdjacentSession(1)
                return true
            case "{", "[":
                store.selectAdjacentSession(-1)
                return true
            default:
                break
            }
        }
        return false
    }

    // MARK: - Menus

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenuItem(appMenu()))
        main.addItem(submenuItem(sessionMenu()))
        main.addItem(submenuItem(editMenu()))
        main.addItem(submenuItem(viewMenu()))
        let window = windowMenu()
        main.addItem(submenuItem(window))
        NSApp.windowsMenu = window
        return main
    }

    private func appMenu() -> NSMenu {
        let name = ConchInfo.appName
        let menu = NSMenu(title: name)
        menu.addItem(item("About \(name)", #selector(showAbout(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings(_:)), ","))
        menu.addItem(.separator())
        menu.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h", target: .application))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: .application))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: .application))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q", target: .application))
        return menu
    }

    private func sessionMenu() -> NSMenu {
        let menu = NSMenu(title: "Session")
        menu.addItem(item("New Claude Session", #selector(newClaudeSession(_:)), "n"))
        menu.addItem(item("New Terminal", #selector(newTerminal(_:)), "t"))
        menu.addItem(item("New Web Session", #selector(newWebSession(_:)), "N"))
        addWorktreeMenuItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(item("Open Folder…", #selector(openFolder(_:)), "o"))
        menu.addItem(item("Quick Open", #selector(quickOpen(_:)), "p"))
        menu.addItem(.separator())
        menu.addItem(item("Split Right with Terminal", #selector(splitRightTerminal(_:)), "d"))
        menu.addItem(item("Split Right with Claude", #selector(splitRightClaude(_:)), "D"))
        menu.addItem(.separator())
        menu.addItem(item("Rename", #selector(renameSession(_:)), "R"))
        menu.addItem(item("Close", #selector(closeSession(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item("Clear Scrollback", #selector(clearScrollback(_:)), "k"))
        menu.addItem(.separator())
        menu.addItem(item("Open Project Folder", #selector(openProjectFolder(_:)), "O"))
        menu.addItem(item("Reveal in Finder", #selector(revealInFinder(_:))))
        menu.addItem(item("Open in VS Code", #selector(openInEditor(_:))))
        menu.addItem(item("Copy Path", #selector(copyPath(_:))))
        menu.addItem(item("Copy Session ID", #selector(copySessionID(_:)), "C"))
        addLayoutMenuItems(to: menu)
        addContextMenuItems(to: menu)
        return menu
    }

    /// Edit actions go down the responder chain (nil target) so the terminal, the palette field and the rename
    /// field each handle them. SwiftTerm implements copy(_:), paste(_:) and selectAll(_:). Find goes straight to the
    /// active terminal: once SwiftTerm's find bar has focus, its field editor would otherwise take the action and
    /// refuse it.
    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z", target: .responderChain))
        menu.addItem(item("Redo", Selector(("redo:")), "Z", target: .responderChain))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x", target: .responderChain))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c", target: .responderChain))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v", target: .responderChain))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a", target: .responderChain))
        menu.addItem(.separator())
        let find = #selector(terminalFind(_:))
        menu.addItem(item("Find…", find, "f", tag: Int(NSFindPanelAction.showFindPanel.rawValue)))
        menu.addItem(item("Find Next", find, "g", tag: Int(NSFindPanelAction.next.rawValue)))
        menu.addItem(item("Find Previous", find, "G", tag: Int(NSFindPanelAction.previous.rawValue)))
        menu.addItem(item("Use Selection for Find", find, "e", tag: Int(NSFindPanelAction.setFindString.rawValue)))
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Toggle Sidebar", #selector(toggleSidebarMenu(_:)), "b"))
        menu.addItem(item("Command Palette", #selector(showCommandPalette(_:)), "P"))
        menu.addItem(item("Keyboard Shortcuts", #selector(showShortcuts(_:)), "/"))
        menu.addItem(.separator())
        menu.addItem(item("Bigger", #selector(biggerText(_:)), "="))
        menu.addItem(item("Smaller", #selector(smallerText(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(actualSizeText(_:)), "0"))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], target: .responderChain))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: .responderChain))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), target: .responderChain))
        menu.addItem(.separator())
        menu.addItem(item("Next Session", #selector(nextSession(_:)), "]", [.command, .shift]))
        menu.addItem(item("Previous Session", #selector(previousSession(_:)), "[", [.command, .shift]))
        menu.addItem(item("Next Pane", #selector(nextPane(_:)), Self.functionKey(NSRightArrowFunctionKey), [.command, .option]))
        menu.addItem(item("Previous Pane", #selector(previousPane(_:)), Self.functionKey(NSLeftArrowFunctionKey), [.command, .option]))
        addAttentionMenuItems(to: menu)
        addModulesMenuItems(to: menu)
        menu.addItem(.separator())
        for index in 0..<9 {
            menu.addItem(item("Session \(index + 1)", #selector(selectSessionByIndex(_:)), "\(index + 1)", tag: index))
        }
        menu.addItem(.separator())
        return menu
    }

    private func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    enum MenuTarget {
        /// This delegate. Nearly every app action.
        case delegate
        case application
        /// nil target: first responder down the responder chain.
        case responderChain
    }

    /// An uppercase letter as the key implies Shift.
    func item(_ title: String,
                      _ action: Selector,
                      _ key: String = "",
                      _ modifiers: NSEvent.ModifierFlags = .command,
                      target: MenuTarget = .delegate,
                      tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        switch target {
        case .delegate: item.target = self
        case .application: item.target = NSApp
        case .responderChain: item.target = nil
        }
        item.tag = tag
        return item
    }

    private static func functionKey(_ key: Int) -> String {
        String(format: "%C", unichar(key))
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // A hidden or minimized window must not let Cmd+W or Cmd+K act on a session nobody can see.
        let windowShown = AppActions.mainWindow.map { $0.isVisible && !$0.isMiniaturized } ?? false
        let hasActive = windowShown && store.activeSession != nil
        switch menuItem.action {
        case #selector(terminalFind(_:)):
            guard otherKeyWindow() == nil, hasActive, let view = store.activeSession?.view else { return false }
            return view.validateUserInterfaceItem(menuItem)
        case #selector(splitRightTerminal(_:)), #selector(splitRightClaude(_:)),
             #selector(renameSession(_:)), #selector(clearScrollback(_:)),
             #selector(revealInFinder(_:)), #selector(openInEditor(_:)), #selector(copyPath(_:)),
             #selector(openProjectFolder(_:)), #selector(copySessionID(_:)):
            return hasActive
        case #selector(closeSession(_:)):
            return otherKeyWindow() != nil || hasActive
        case #selector(nextSession(_:)), #selector(previousSession(_:)):
            return store.allSessions.count > 1
        case #selector(nextPane(_:)), #selector(previousPane(_:)):
            return (store.selectedGroup?.sessions.count ?? 0) > 1
        case #selector(selectSessionByIndex(_:)):
            return menuItem.tag < store.groups.count
        default:
            return true
        }
    }

    // MARK: - Actions

    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: ConchInfo.appName,
            .applicationVersion: ConchInfo.version,
            .version: "",
        ])
        AppActions.activateApp()
    }

    @objc private func showSettings(_ sender: Any?) { AppActions.showSettings() }
    @objc private func newClaudeSession(_ sender: Any?) { AppActions.newClaude() }
    @objc private func newTerminal(_ sender: Any?) { AppActions.newTerminal() }
    @objc private func newWebSession(_ sender: Any?) { AppActions.showNewCloudSession() }
    @objc private func openFolder(_ sender: Any?) { AppActions.openFolder() }
    @objc private func quickOpen(_ sender: Any?) { AppActions.showQuickOpen() }
    @objc private func splitRightTerminal(_ sender: Any?) { AppActions.newTerminal(split: true) }
    @objc private func splitRightClaude(_ sender: Any?) { AppActions.newClaude(split: true) }

    @objc private func renameSession(_ sender: Any?) {
        guard let session = store.activeSession else { return }
        AppActions.beginRename(session)
    }

    /// Cmd+W closes the active session, unless another window such as Settings is key, which it closes instead.
    @objc private func closeSession(_ sender: Any?) {
        if let other = otherKeyWindow() {
            other.performClose(sender)
            return
        }
        guard let session = store.activeSession else { return }
        AppActions.requestClose(session)
    }

    @objc private func clearScrollback(_ sender: Any?) { store.activeSession?.clearScrollback() }

    @objc private func terminalFind(_ sender: Any?) { store.activeSession?.view.performFindPanelAction(sender) }

    @objc private func showShortcuts(_ sender: Any?) { ShortcutsOverlay.toggle() }

    @objc private func openProjectFolder(_ sender: Any?) {
        guard let group = store.selectedGroup else { return }
        AppActions.openProjectFolder(store.project(of: group).root)
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let session = store.activeSession else { return }
        AppActions.revealInFinder(session.currentDirectory)
    }

    @objc private func openInEditor(_ sender: Any?) {
        guard let session = store.activeSession else { return }
        AppActions.openInEditor(session.currentDirectory)
    }

    @objc private func copySessionID(_ sender: Any?) {
        guard let session = store.activeSession else { return }
        AppActions.copySessionID(session)
    }

    @objc private func copyPath(_ sender: Any?) {
        guard let session = store.activeSession else { return }
        AppActions.copyToPasteboard(session.currentDirectory)
    }

    @objc private func toggleSidebarMenu(_ sender: Any?) { AppActions.toggleSidebar() }
    @objc private func showCommandPalette(_ sender: Any?) { AppActions.showCommandPalette() }
    @objc private func biggerText(_ sender: Any?) { AppActions.adjustFontSize(1) }
    @objc private func smallerText(_ sender: Any?) { AppActions.adjustFontSize(-1) }
    @objc private func actualSizeText(_ sender: Any?) { AppActions.adjustFontSize(0) }
    @objc private func nextSession(_ sender: Any?) { store.selectAdjacentSession(1) }
    @objc private func previousSession(_ sender: Any?) { store.selectAdjacentSession(-1) }
    @objc private func nextPane(_ sender: Any?) { store.focusAdjacentPane(1) }
    @objc private func previousPane(_ sender: Any?) { store.focusAdjacentPane(-1) }

    @objc private func selectSessionByIndex(_ sender: NSMenuItem) {
        store.selectGroup(at: sender.tag)
    }

    /// A key window that is neither the main window nor a panel attached to it, such as Settings or About.
    private func otherKeyWindow() -> NSWindow? {
        guard let key = NSApp.keyWindow else { return nil }
        let main = windowController?.window
        if key === main || (main != nil && key.parent === main) { return nil }
        return key
    }
}
