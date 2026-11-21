import AppKit
import Combine
import SwiftUI

// Owner: shell agent.

/// Content area of the main window. Every group has a split view that stays alive for the life of the group, and
/// only the selected one is shown, so switching never tears down a terminal view.
@MainActor
final class TerminalContainerViewController: NSViewController {
    /// Called after every sync, which covers selection, group membership and focus changes.
    var onStateChange: (() -> Void)?

    private let store: SessionStore
    private var groupViews: [UUID: ConchGroupSplitView] = [:]
    private var panes: [UUID: ConchPaneView] = [:]
    private var groupObservations: [UUID: AnyCancellable] = [:]
    private var storeObservation: AnyCancellable?
    private var syncScheduled = false
    private var shownGroupID: UUID?
    private var shownFocusedID: UUID?
    private var lastDark: Bool?
    private var emptyState: NSView?

    init(store: SessionStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let container = ConchContainerView(frame: NSRect(x: 0, y: 0, width: 950, height: 760))
        container.onAppearanceChange = { [weak self] in self?.appearanceChanged() }
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        storeObservation = store.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }
        sync()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Equalizing moves dividers, which is not allowed in the middle of a layout pass.
        if groupViews.values.contains(where: \.needsEqualWidths) {
            DispatchQueue.main.async { [weak self] in self?.equalizePending() }
        }
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - Sync

    /// Store and group publishers fire in willSet, so the new state is read on the next main queue turn.
    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.sync()
        }
    }

    private func sync() {
        let groups = store.groups
        let liveGroupIDs = Set(groups.map(\.id))
        let liveSessionIDs = Set(groups.flatMap { $0.sessions.map(\.id) })

        for (id, observation) in groupObservations where !liveGroupIDs.contains(id) {
            observation.cancel()
            groupObservations[id] = nil
        }
        for group in groups where groupObservations[group.id] == nil {
            groupObservations[group.id] = group.objectWillChange.sink { [weak self] _ in self?.scheduleSync() }
        }

        for (id, pane) in panes where !liveSessionIDs.contains(id) {
            pane.detach()
            panes[id] = nil
        }
        for (id, groupView) in groupViews where !liveGroupIDs.contains(id) {
            groupView.removeFromSuperview()
            groupViews[id] = nil
        }

        for group in groups {
            arrangePanes(of: group, in: groupView(for: group))
        }

        let selectedID = store.selectedGroup?.id
        for (id, groupView) in groupViews {
            groupView.isHidden = id != selectedID
        }
        updateEmptyState(isEmpty: groups.isEmpty)

        if groupViews.values.contains(where: \.needsEqualWidths) {
            view.layoutSubtreeIfNeeded()
            equalizePending()
        }

        focusIfNeeded()
        onStateChange?()
    }

    private func groupView(for group: SessionGroup) -> ConchGroupSplitView {
        if let existing = groupViews[group.id] { return existing }
        let groupView = ConchGroupSplitView()
        install(groupView)
        groupViews[group.id] = groupView
        return groupView
    }

    /// Makes the split view's panes match `group.sessions`, in order. Panes are reused, never rebuilt.
    private func arrangePanes(of group: SessionGroup, in groupView: ConchGroupSplitView) {
        let wanted = group.sessions.map(\.id)
        let current = groupView.arrangedSubviews.compactMap { ($0 as? ConchPaneView)?.sessionID }
        guard wanted != current else { return }

        let paneCountBefore = current.count
        for (index, session) in group.sessions.enumerated() {
            let pane = panes[session.id] ?? makePane(for: session)
            let arranged = groupView.arrangedSubviews
            if index < arranged.count, arranged[index] === pane { continue }
            // Inserting reparents the pane, which also covers a session that moved between groups.
            pane.removeFromSuperview()
            groupView.insertArrangedSubview(pane, at: min(index, groupView.arrangedSubviews.count))
        }
        for extra in groupView.arrangedSubviews.dropFirst(wanted.count) {
            extra.removeFromSuperview()
        }
        if wanted.count != paneCountBefore { groupView.needsEqualWidths = true }
    }

    private func makePane(for session: TerminalSession) -> ConchPaneView {
        let pane = ConchPaneView(sessionID: session.id, terminal: session.view)
        panes[session.id] = pane
        return pane
    }

    private func equalizePending() {
        for groupView in groupViews.values where groupView.needsEqualWidths {
            groupView.equalizeWidths()
        }
    }

    /// Focuses the selected group's focused pane when the selection moved, or when focus fell off a closed pane.
    private func focusIfNeeded() {
        guard let group = store.selectedGroup, let session = group.focusedSession else {
            shownGroupID = nil
            shownFocusedID = nil
            return
        }
        let groupChanged = group.id != shownGroupID
        let focusChanged = session.id != shownFocusedID
        shownGroupID = group.id
        shownFocusedID = session.id

        // An inline rename in the sidebar owns the keyboard until it commits or cancels.
        guard store.renamingSessionID == nil, let window = view.window else { return }
        let responder = window.firstResponder
        let alreadyFocused = responder === session.view
            || ((responder as? NSView)?.isDescendant(of: session.view) ?? false)
        let focusLost = responder == nil || responder === window
        if groupChanged || (focusChanged && !alreadyFocused) || focusLost {
            session.focus()
        }
    }

    // MARK: - Appearance

    private func appearanceChanged() {
        let dark = Self.isDark(view.effectiveAppearance)
        defer { lastDark = dark }
        guard let lastDark, lastDark != dark else { return }
        // Let AppKit finish propagating the appearance before the terminals read it.
        DispatchQueue.main.async { [weak self] in self?.store.applyAppearanceToAll() }
    }

    // MARK: - Helpers

    /// Pins a full-size child below the titlebar. The content item extends under the toolbar, so the top edge
    /// follows the safe area.
    private func install(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// The empty state only exists while there are no groups, so it costs nothing while terminals are open.
    private func updateEmptyState(isEmpty: Bool) {
        if isEmpty, emptyState == nil {
            let hosting = NSHostingView(rootView: EmptyStateView(store: store))
            hosting.sizingOptions = []
            install(hosting)
            emptyState = hosting
        } else if !isEmpty, let emptyState {
            emptyState.removeFromSuperview()
            self.emptyState = nil
        }
    }
}

// MARK: - Views

/// Root view of the content area. Reports light and dark switches.
private final class ConchContainerView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAppearanceChange?() }
    }
}

/// One group: panes side by side.
private final class ConchGroupSplitView: NSSplitView {
    /// Set when panes were added or removed, cleared once the split view has a width to divide.
    var needsEqualWidths = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 950, height: 700))
        isVertical = true
        dividerStyle = .thin
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func equalizeWidths() {
        let count = arrangedSubviews.count
        guard bounds.width > 0 else { return }
        needsEqualWidths = false
        guard count > 1 else { return }
        let divider = dividerThickness
        let width = (bounds.width - divider * CGFloat(count - 1)) / CGFloat(count)
        // A divider cannot pass its neighbour, so a second pass settles any that were blocked on the first.
        for _ in 0..<2 {
            for index in 0..<(count - 1) {
                setPosition(width * CGFloat(index + 1) + divider * CGFloat(index), ofDividerAt: index)
            }
        }
    }
}

/// A terminal inset by a few points on the terminal background colour.
private final class ConchPaneView: NSView {
    static let padding: CGFloat = 6

    let sessionID: UUID
    private let terminal: NSView

    init(sessionID: UUID, terminal: NSView) {
        self.sessionID = sessionID
        self.terminal = terminal
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        wantsLayer = true
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        let padding = Self.padding
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = TerminalContainerViewController.isDark(effectiveAppearance)
        layer?.backgroundColor = TerminalTheme.background(dark: dark).cgColor
    }

    /// A click on the padding focuses the terminal, which reports the focus to the store through onFocus.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminal)
    }

    /// Takes the terminal out of the window. SwiftTerm stops its render loop and timers when it loses its window.
    func detach() {
        terminal.removeFromSuperview()
        removeFromSuperview()
    }
}
