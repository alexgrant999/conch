import AppKit
import Combine
import SwiftUI

enum PaletteMode {
    /// Open sessions and projects. Enter on a project starts Claude there, Cmd+Enter a terminal.
    /// A pasted `session_...` id or claude.ai/code URL offers "Attach to web session". A pasted local session id
    /// (or `claude --resume <id>`) with a transcript offers "Resume Claude session".
    case quickOpen
    /// Commands (New Terminal, New Claude Session, Split, Close, Rename, Settings and so on).
    case commands
    /// Single text prompt: describe a task, Enter starts `claude --cloud "<description>"` in the active directory.
    case newCloudSession
}

@MainActor
final class CommandPaletteController {
    static let shared = CommandPaletteController()

    private var panel: PalettePanel?
    private var model: PaletteModel?
    private var keyMonitor: Any?
    private weak var parentWindow: NSWindow?

    private var projects: [ProjectEntry] = []
    private var projectsRoots: [String] = []
    private var projectsScannedAt: Date?
    private var isScanning = false
    private static let projectCacheLifetime: TimeInterval = 60

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows the palette as a child panel centred near the top of `window`. Calling it while visible switches mode.
    func show(mode: PaletteMode, in window: NSWindow) {
        if let panel, let model, panel.isVisible, parentWindow === window {
            model.setMode(mode)
            panel.makeKey()
            refreshProjectsIfNeeded()
            return
        }
        hide()

        if !window.isVisible { window.makeKeyAndOrderFront(nil) }

        let model = PaletteModel(mode: mode, store: SessionStore.shared, projects: projects)
        let panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: PaletteLayout.width, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: PaletteLayout.width, height: 200))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        // A layer corner radius does not clip a behind-window blur; a stretchable mask image does.
        effect.maskImage = PalettePanel.roundedMask(radius: PaletteLayout.cornerRadius)

        let hosting = NSHostingView(rootView: PaletteView(model: model))
        // Default sizing options add min/max constraints that fight the autoresizing mask.
        hosting.sizingOptions = []
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        panel.contentView = effect

        model.onRun = { [weak self] item, secondary in self?.run(item, secondary: secondary) }
        model.onLayoutChange = { [weak self] in self?.layout() }
        panel.onResignKey = { [weak self] in self?.hide() }

        self.panel = panel
        self.model = model
        parentWindow = window

        layout()
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        refreshProjectsIfNeeded()
        ConversationIndex.shared.refreshIfNeeded { [weak self] conversations in
            self?.model?.conversations = conversations
        }
    }

    func hide() {
        guard let panel else { return }
        self.panel = nil
        model = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.onResignKey = nil
        let parent = parentWindow
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if let parent, parent.isVisible, NSApp.isActive, NSApp.keyWindow == nil {
            parent.makeKey()
        }
    }

    private func run(_ item: PaletteItem, secondary: Bool) {
        let action = secondary ? (item.secondary ?? item.primary) : item.primary
        if item.keepsOpen {
            action()
            return
        }
        // Hide first so the main window is key again before the action moves focus or opens a sheet.
        hide()
        action()
    }

    private func layout() {
        guard let panel, let model, let parent = parentWindow else { return }
        let width = min(PaletteLayout.width, max(320, parent.frame.width - 40))
        let height = PaletteLayout.height(mode: model.mode, itemCount: model.items.count)
        // contentLayoutRect excludes the title bar and toolbar, so the panel sits just under them.
        let top = parent.frame.minY + parent.contentLayoutRect.maxY - 10
        let frame = NSRect(x: (parent.frame.midX - width / 2).rounded(), y: (top - height).rounded(), width: width, height: height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, let model = self.model,
                  event.window === panel, panel.isKeyWindow else { return event }
            return self.handle(event, model: model, panel: panel) ? nil : event
        }
    }

    private func handle(_ event: NSEvent, model: PaletteModel, panel: NSPanel) -> Bool {
        // While an input method is composing, Escape, arrows and Return belong to it.
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        switch event.keyCode {
        case 53: // Escape
            hide()
            return true
        case 126: // Up
            model.moveHighlight(-1)
            return true
        case 125: // Down
            model.moveHighlight(1)
            return true
        case 36, 76: // Return, keypad Enter
            let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
            model.activate(secondary: command)
            return true
        default:
            return false
        }
    }

    private func refreshProjectsIfNeeded() {
        guard model?.mode == .quickOpen, !isScanning else { return }
        let roots = SessionStore.shared.settings.projectRoots
        if roots == projectsRoots, let scannedAt = projectsScannedAt,
           Date().timeIntervalSince(scannedAt) < Self.projectCacheLifetime {
            return
        }
        isScanning = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let entries = ProjectScanner.scan(roots: roots)
            await self?.projectsScanned(entries, roots: roots)
        }
    }

    private func projectsScanned(_ entries: [ProjectEntry], roots: [String]) {
        isScanning = false
        projects = entries
        projectsRoots = roots
        projectsScannedAt = Date()
        model?.projects = entries
    }
}

final class PalettePanel: NSPanel {
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Shared by the panel frame and the SwiftUI layout so the window always fits its rows exactly.
enum PaletteLayout {
    static let width: CGFloat = 620
    static let cornerRadius: CGFloat = 12
    static let fieldHeight: CGFloat = 50
    static let rowHeight: CGFloat = 30
    static let listPadding: CGFloat = 6
    static let maxVisibleRows = 10
    static let cloudFooterHeight: CGFloat = 56

    static func height(mode: PaletteMode, itemCount: Int) -> CGFloat {
        switch mode {
        case .newCloudSession:
            return fieldHeight + 1 + cloudFooterHeight
        case .quickOpen, .commands:
            let rows = max(1, min(itemCount, maxVisibleRows))
            return fieldHeight + 1 + CGFloat(rows) * rowHeight + listPadding * 2
        }
    }
}

struct PaletteItem: Identifiable {
    let id: String
    let symbol: String
    var tint: Color? = nil
    let title: String
    var titleMatches: [Int] = []
    var detail: String? = nil
    var hint: String? = nil
    /// Mode switches keep the palette open, everything else closes it before running.
    var keepsOpen = false
    let primary: () -> Void
    var secondary: (() -> Void)? = nil
}

@MainActor
final class PaletteModel: ObservableObject {
    @Published private(set) var mode: PaletteMode
    @Published var query = "" {
        didSet { if query != oldValue { rebuild(keepHighlight: false) } }
    }
    @Published private(set) var items: [PaletteItem] = []
    @Published var highlighted = 0
    /// Where a new web session runs, captured when the mode opens.
    @Published private(set) var cloudDirectory: String

    var projects: [ProjectEntry] {
        didSet { if mode == .quickOpen { rebuild(keepHighlight: true) } }
    }
    /// Recent Claude conversations on disk, loaded by ConversationIndex.
    var conversations: [ConversationSummary] = [] {
        didSet { if mode == .quickOpen { rebuild(keepHighlight: true) } }
    }

    var onRun: (PaletteItem, Bool) -> Void = { _, _ in }
    var onLayoutChange: () -> Void = {}

    let store: SessionStore
    private let recentDirectories: [String]
    private static let maxDirectoryItems = 40

    init(mode: PaletteMode, store: SessionStore, projects: [ProjectEntry]) {
        self.mode = mode
        self.store = store
        self.projects = projects
        cloudDirectory = store.defaultDirectory()
        recentDirectories = store.settings.recentDirectories.filter { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        rebuild(keepHighlight: false)
    }

    var placeholder: String {
        switch mode {
        case .quickOpen: return "Search sessions and projects"
        case .commands: return "Type a command"
        case .newCloudSession: return "Describe a task for a new Claude Code web session"
        }
    }

    var symbol: String {
        switch mode {
        case .quickOpen: return "magnifyingglass"
        case .commands: return "command"
        case .newCloudSession: return "cloud"
        }
    }

    func setMode(_ newMode: PaletteMode) {
        mode = newMode
        if newMode == .newCloudSession { cloudDirectory = store.defaultDirectory() }
        if query.isEmpty {
            rebuild(keepHighlight: false)
        } else {
            query = ""
        }
    }

    func moveHighlight(_ delta: Int) {
        guard !items.isEmpty else { return }
        highlighted = (highlighted + delta + items.count) % items.count
    }

    func activate(secondary: Bool) {
        switch mode {
        case .newCloudSession:
            let target = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else {
                NSSound.beep()
                return
            }
            let store = self.store
            let dir = cloudDirectory
            onRun(PaletteItem(id: "cloud", symbol: "cloud", title: target) { store.newCloud(target: target, in: dir) }, false)
        case .quickOpen, .commands:
            guard items.indices.contains(highlighted) else { return }
            onRun(items[highlighted], secondary)
        }
    }

    func activate(index: Int, secondary: Bool) {
        guard items.indices.contains(index) else { return }
        highlighted = index
        activate(secondary: secondary)
    }

    private func rebuild(keepHighlight: Bool) {
        let previousID = items.indices.contains(highlighted) ? items[highlighted].id : nil
        switch mode {
        case .quickOpen: items = quickOpenItems()
        case .commands: items = commandItems()
        case .newCloudSession: items = []
        }
        if keepHighlight, let previousID, let index = items.firstIndex(where: { $0.id == previousID }) {
            highlighted = index
        } else {
            highlighted = 0
        }
        onLayoutChange()
    }

    private func quickOpenItems() -> [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = self.store
        var result: [PaletteItem] = []

        if !q.isEmpty, LaunchCommand.isCloudAttachTarget(q) {
            let dir = store.defaultDirectory()
            result.append(PaletteItem(
                id: "attach", symbol: "cloud", title: "Attach to web session", detail: q, hint: "↩ Attach",
                primary: { store.newCloud(target: q, in: dir) }
            ))
        }

        if !q.isEmpty, let target = LaunchCommand.resumeTarget(in: q) {
            result.append(PaletteItem(
                id: "resume", symbol: "arrow.uturn.backward", tint: SessionGlyph.tint(for: .claude),
                title: "Resume Claude session", detail: target.directory?.abbreviatingHome ?? q, hint: "↩ Resume",
                primary: { store.resumeClaude(sessionID: target.sessionID, in: target.directory) }
            ))
        }

        var sessions: [(score: Int, order: Int, item: PaletteItem)] = []
        for (order, session) in store.allSessions.enumerated() {
            let name = session.displayName
            let place = SidebarPath.shortDirectory(session.currentDirectory)
            let score: Int
            var positions: [Int] = []
            if let match = FuzzyMatcher.match(q, in: name) {
                score = match.score
                positions = match.positions
            } else if let match = FuzzyMatcher.match(q, in: place) {
                score = match.score - 20
            } else {
                continue
            }
            let kind = session.spec.kind
            sessions.append((score, order, PaletteItem(
                id: "session:\(session.id.uuidString)",
                symbol: SessionGlyph.symbol(for: kind), tint: SessionGlyph.tint(for: kind),
                title: name, titleMatches: positions, detail: place, hint: "↩ Switch",
                primary: { store.select(session) }
            )))
        }
        result += Self.ranked(sessions)
        result += layoutItems(query: q)
        result += recentConversationItems(query: q)

        var seen = Set<String>()
        var directories: [(score: Int, order: Int, item: PaletteItem)] = []
        func addDirectory(path: String, name: String, detail: String, symbol: String, bonus: Int) {
            guard seen.insert((path as NSString).standardizingPath).inserted else { return }
            let score: Int
            var positions: [Int] = []
            if let match = FuzzyMatcher.match(q, in: name) {
                score = match.score
                positions = match.positions
            } else if let match = FuzzyMatcher.match(q, in: path.abbreviatingHome) {
                score = match.score - 15
            } else {
                return
            }
            directories.append((score + bonus, directories.count, PaletteItem(
                id: "dir:\(path)", symbol: symbol, title: name, titleMatches: positions, detail: detail,
                hint: "↩ Claude  ⌘↩ Terminal",
                primary: { AppActions.newClaude(in: path) },
                secondary: { AppActions.newTerminal(in: path) }
            )))
        }
        for (rank, path) in recentDirectories.enumerated() {
            let parent = (path as NSString).deletingLastPathComponent
            addDirectory(path: path, name: path.lastPathComponentOrSelf, detail: parent.abbreviatingHome,
                         symbol: "clock", bonus: max(0, 10 - rank))
        }
        for entry in projects {
            addDirectory(path: entry.path, name: entry.name, detail: entry.detail, symbol: "folder", bonus: 0)
        }
        result += Self.ranked(directories, ordered: q.isEmpty).prefix(Self.maxDirectoryItems)
        result += moduleItems(query: q)
        return result
    }

    private func commandItems() -> [PaletteItem] {
        let store = self.store
        let active = store.activeSession

        func command(_ title: String, _ symbol: String, _ shortcut: String?, tint: Color? = nil,
                     detail: String? = nil, action: @escaping () -> Void) -> PaletteItem {
            PaletteItem(id: "cmd:\(title)", symbol: symbol, tint: tint, title: title, detail: detail,
                        hint: shortcut, primary: action)
        }

        var all: [PaletteItem] = [
            command("New Claude Session", "sparkle", "⌘N", tint: SessionGlyph.claudeOrange) { AppActions.newClaude() },
            command("New Terminal", "terminal", "⌘T") { AppActions.newTerminal() },
            PaletteItem(id: "cmd:New Web Session", symbol: "cloud", title: "New Web Session", hint: "⇧⌘N",
                        keepsOpen: true, primary: { [weak self] in self?.setMode(.newCloudSession) }),
            command("Open Folder", "folder", "⌘O") { AppActions.openFolder() },
        ]
        if let active {
            let name = active.displayName
            all += [
                command("Split Right with Terminal", "rectangle.split.2x1", "⌘D") { AppActions.newTerminal(split: true) },
                command("Split Right with Claude", "rectangle.split.2x1", "⇧⌘D") { AppActions.newClaude(split: true) },
                command("Rename Session", "pencil", "⇧⌘R", detail: name) { AppActions.beginRename(active) },
                command("Close Session", "xmark", "⌘W", detail: name) { AppActions.requestClose(active) },
                command("Clear Scrollback", "eraser", "⌘K", detail: name) { active.clearScrollback() },
            ]
        }
        all += codexCommands() + worktreeCommands() + layoutCommands() + contextCommands() + modelCommands() + reviewCommands()
            + attentionCommands()
        all += moduleCommands()
        all += [
            command("Toggle Sidebar", "sidebar.left", "⌘B") { AppActions.toggleSidebar() },
            command("Bigger Text", "plus.magnifyingglass", "⌘=") { AppActions.adjustFontSize(1) },
            command("Smaller Text", "minus.magnifyingglass", "⌘-") { AppActions.adjustFontSize(-1) },
        ]
        if let active {
            let dir = active.currentDirectory
            all += [
                command("Reveal in Finder", "folder", nil, detail: dir.abbreviatingHome) { AppActions.revealInFinder(dir) },
                command("Open in VS Code", "chevron.left.forwardslash.chevron.right", nil, detail: dir.abbreviatingHome) {
                    AppActions.openInEditor(dir)
                },
            ]
        }
        let settings = store.settings
        all += [
            command("Settings", "gearshape", "⌘,") { AppActions.showSettings() },
            command("Remote Control for New Sessions: \(settings.remoteControlByDefault ? "On" : "Off")",
                    "dot.radiowaves.left.and.right", nil) { settings.remoteControlByDefault.toggle() },
        ]

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        var hits: [(score: Int, order: Int, item: PaletteItem)] = []
        for (order, var item) in all.enumerated() {
            guard let match = FuzzyMatcher.match(q, in: item.title) else { continue }
            item.titleMatches = match.positions
            hits.append((match.score, order, item))
        }
        return Self.ranked(hits)
    }

    /// Best score first, original order on ties. `ordered` keeps the original order (empty query).
    static func ranked(_ entries: [(score: Int, order: Int, item: PaletteItem)], ordered: Bool = false) -> [PaletteItem] {
        let sorted = ordered ? entries : entries.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.order < rhs.order
        }
        return sorted.map(\.item)
    }
}

struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                TextField(model.placeholder, text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($fieldFocused)
            }
            .padding(.horizontal, 16)
            .frame(height: PaletteLayout.fieldHeight)

            Divider()

            if model.mode == .newCloudSession {
                cloudFooter
            } else {
                results
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            RoundedRectangle(cornerRadius: PaletteLayout.cornerRadius)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onAppear {
            // The panel is not key yet during onAppear; ask on the next turn of the run loop.
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if model.items.isEmpty {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: PaletteLayout.rowHeight)
                    }
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        PaletteRow(item: item, isHighlighted: index == model.highlighted)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let command = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
                                model.activate(index: index, secondary: command)
                            }
                    }
                }
                .padding(.vertical, PaletteLayout.listPadding)
                .padding(.horizontal, 6)
            }
            .onChange(of: model.highlighted) { _, index in
                guard model.items.indices.contains(index) else { return }
                proxy.scrollTo(model.items[index].id)
            }
        }
    }

    private var cloudFooter: some View {
        let target = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let attaching = !target.isEmpty && LaunchCommand.isCloudAttachTarget(target)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Runs in \(model.cloudDirectory.abbreviatingHome)", systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label("Paste a claude.ai/code link to attach instead", systemImage: "link")
            }
            Spacer(minLength: 8)
            Text(attaching ? "↩ Attach" : "↩ Start")
                .opacity(target.isEmpty ? 0 : 1)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: PaletteLayout.cloudFooterHeight)
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .foregroundStyle(isHighlighted ? Color.white : (item.tint ?? Color.secondary))
                .frame(width: 18)
            Text(title)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = item.detail {
                Text(detail)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let hint = item.hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryColor)
                    .fixedSize()
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: PaletteLayout.rowHeight)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .selectedContentBackgroundColor))
            }
        }
    }

    private var secondaryColor: Color {
        isHighlighted ? Color.white.opacity(0.8) : Color.secondary
    }

    /// Matched characters in bold.
    private var title: AttributedString {
        var text = AttributedString(item.title)
        guard !item.titleMatches.isEmpty else { return text }
        let matched = Set(item.titleMatches)
        var index = text.startIndex
        var offset = 0
        while index < text.endIndex {
            let next = text.characters.index(after: index)
            if matched.contains(offset) {
                text[index..<next].inlinePresentationIntent = .stronglyEmphasized
            }
            index = next
            offset += 1
        }
        return text
    }
}
