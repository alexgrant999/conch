import AppKit
import Combine
import SwiftUI

// Owner: shell agent.

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let store: SessionStore

    private static let frameAutosaveName = "ConchMainWindow"
    private let splitController = NSSplitViewController()
    private let sidebarItem: NSSplitViewItem
    private let container: TerminalContainerViewController

    private var observedSessionID: UUID?
    private var sessionObservation: AnyCancellable?

    private let usageState = UsageStripState()
    private lazy var usageHost = NSHostingView(rootView: UsageStrip(monitor: .shared, state: usageState))
    private var usageObservations: Set<AnyCancellable> = []

    init(store: SessionStore) {
        self.store = store
        let sidebarHost = NSHostingController(rootView: SidebarView(store: store))
        // The split view owns the sidebar width, so SwiftUI must not push size constraints onto it.
        sidebarHost.sizingOptions = []
        sidebarHost.view.setFrameSize(NSSize(width: 250, height: 760))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        container = TerminalContainerViewController(store: store)
        super.init(window: nil)
        buildWindow()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func toggleSidebar() {
        splitController.toggleSidebar(nil)
    }

    // MARK: - Internal API for AppActions and AppDelegate

    func showMainWindow() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        AppActions.activateApp()
        store.recomputeVisibility()
    }

    /// Expands the sidebar when it is collapsed, so an inline rename is visible.
    func revealSidebar() {
        if sidebarItem.isCollapsed { sidebarItem.animator().isCollapsed = false }
    }

    /// Toolbar button and responder chain fallback when no view inside the split view is first responder.
    @objc func toggleSidebar(_ sender: Any?) {
        toggleSidebar()
    }

    // MARK: - Window

    private func buildWindow() {
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true

        container.view.setFrameSize(NSSize(width: 950, height: 760))
        let contentItem = NSSplitViewItem(viewController: container)
        contentItem.minimumThickness = 320

        // Test runs (CONCH_STATE_PATH) must not write window geometry into the user's real defaults.
        let isolated = !(ProcessInfo.processInfo.environment["CONCH_STATE_PATH"] ?? "").isEmpty
        if !isolated { splitController.splitView.autosaveName = "ConchSidebarSplit" }
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(contentItem)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.contentViewController = splitController
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.contentMinSize = NSSize(width: 640, height: 400)
        window.title = ConchInfo.appName

        let toolbar = NSToolbar(identifier: "ConchMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // Restore before naming the autosave slot, or the default frame would overwrite the saved one.
        window.center()
        if !isolated {
            window.setFrameUsingName(Self.frameAutosaveName)
            window.setFrameAutosaveName(Self.frameAutosaveName)
        }

        window.delegate = self
        self.window = window

        container.onStateChange = { [weak self] in self?.activeSessionMayHaveChanged() }
        activeSessionMayHaveChanged()
        observeUsageStrip()
    }

    // MARK: - Usage strip

    private func observeUsageStrip() {
        store.settings.$showUsageInToolbar
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] shown in self?.setUsageItemShown(shown) }
            .store(in: &usageObservations)
        container.view.postsFrameChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: container.view)
            .sink { [weak self] _ in self?.updateUsageWidth() }
            .store(in: &usageObservations)
        updateUsageWidth()
    }

    private func setUsageItemShown(_ shown: Bool) {
        guard let toolbar = window?.toolbar else { return }
        let index = toolbar.items.firstIndex { $0.itemIdentifier == .conchUsage }
        if shown, index == nil {
            toolbar.insertItem(withItemIdentifier: .conchUsage, at: toolbar.items.count)
        } else if !shown, let index {
            toolbar.removeItem(at: index)
        }
    }

    /// The window title shares the toolbar with the strip, so the last prompt goes first, then the labels.
    private func updateUsageWidth() {
        let width = container.view.frame.width
        let fit: UsageStripWidth = width >= 600 ? .full : width >= 480 ? .noLastPrompt : .barsOnly
        if usageState.width != fit { usageState.width = fit }
    }

    // MARK: - Title and subtitle

    private func activeSessionMayHaveChanged() {
        let active = store.activeSession
        if active?.id != observedSessionID {
            observedSessionID = active?.id
            usageState.activeSessionID = active?.id
            sessionObservation = active.map { session in
                Publishers.Merge3(
                    session.$customName.map { _ in () },
                    session.$title.map { _ in () },
                    session.$currentDirectory.map { _ in () }
                )
                // @Published emits before the new value is stored, so read it on the next turn.
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.updateTitle() }
            }
        }
        updateTitle()
    }

    private func updateTitle() {
        guard let window else { return }
        let active = store.activeSession
        let title = active?.displayName ?? ConchInfo.appName
        let subtitle = active?.currentDirectory.abbreviatingHome ?? ""
        if window.title != title { window.title = title }
        if window.subtitle != subtitle { window.subtitle = subtitle }
    }

    // MARK: - NSWindowDelegate

    /// The red button hides the window. Sessions keep running and the Dock icon brings it back.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hiding a full-screen window leaves its empty black Space behind, so leave full screen first.
        if sender.styleMask.contains(.fullScreen) {
            hideAfterFullScreenExit = true
            sender.toggleFullScreen(nil)
            return false
        }
        sender.orderOut(nil)
        store.recomputeVisibility()
        return false
    }

    private var hideAfterFullScreenExit = false

    func windowDidExitFullScreen(_ notification: Notification) {
        guard hideAfterFullScreenExit, let window else { return }
        hideAfterFullScreenExit = false
        window.orderOut(nil)
        store.recomputeVisibility()
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace] + (store.settings.showUsageInToolbar ? [.conchUsage] : [])
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .conchUsage]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == .conchUsage else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Usage"
        item.paletteLabel = "Usage"
        item.view = usageHost
        return item
    }
}

private extension NSToolbarItem.Identifier {
    static let conchUsage = NSToolbarItem.Identifier("ConchUsage")
}
