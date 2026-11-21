import AppKit
import Combine
import SwiftUI

// Owner: modules builder (feature/modules-section).

/// Which module the Modules window shows. Set by the sidebar and the palette, and by the window's own list.
@MainActor
final class ModulesWindowModel: ObservableObject {
    @Published var selectedID: String?
    /// The active session's folder with symlinks resolved, for the install picker's Active session group.
    @Published var activeDirectory: String?
}

/// The Modules window (Window menu, ⇧⌘M): modules on the left, the selected one's details and actions on the right.
@MainActor
final class ModulesWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ModulesWindowController()

    let model = ModulesWindowModel()
    private var activeDirectoryObservation: AnyCancellable?

    private init() {
        let hosting = NSHostingController(rootView: ModulesView(library: .shared, model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Modules"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 780, height: 560))
        window.contentMinSize = NSSize(width: 620, height: 400)
        window.center()
        // Test runs (CONCH_STATE_PATH) must not write window geometry into the user's real defaults.
        if !ConchInfo.isIsolated {
            window.setFrameUsingName("ConchModulesWindow")
            window.setFrameAutosaveName("ConchModulesWindow")
        }
        super.init(window: window)
        window.delegate = self
        observeActiveDirectory()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the window, on `moduleID` when given. The list reloads as the window becomes key.
    func present(selecting moduleID: String? = nil) {
        if let moduleID { model.selectedID = moduleID }
        if window?.isKeyWindow == true { ModuleLibrary.shared.reload() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        AppActions.activateApp()
    }

    /// Coming back from a terminal that ran an install picks up the new modules.json.
    func windowDidBecomeKey(_ notification: Notification) {
        ModuleLibrary.shared.reload()
    }

    /// Follows SessionStore.activeSession (the selected group's focused session) and its current folder. Built
    /// from the values the publishers send, since @Published sends before the property changes.
    private func observeActiveDirectory() {
        let store = SessionStore.shared
        let none = Just<String?>(nil).eraseToAnyPublisher()
        activeDirectoryObservation = store.$groups.combineLatest(store.$selectedGroupID)
            .map { groups, selected -> AnyPublisher<String?, Never> in
                guard let group = groups.first(where: { $0.id == selected }) else { return none }
                return group.$sessions.combineLatest(group.$focusedSessionID)
                    .map { sessions, focused in sessions.first { $0.id == focused } ?? sessions.first }
                    .map { session in session.map { $0.$currentDirectory.map(Optional.some).eraseToAnyPublisher() } ?? none }
                    .switchToLatest()
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .map { $0.map { ($0 as NSString).resolvingSymlinksInPath } }
            .removeDuplicates()
            .sink { [weak self] directory in self?.model.activeDirectory = directory }
    }
}
