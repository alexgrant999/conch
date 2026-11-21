import AppKit
import Combine

// Owner: attention builder (feature/attention).

/// Menu bar item: a template icon, plus the number of sessions waiting for you when there are any. Shown while
/// `AppSettings.showInMenuBar` is on. The count follows the store's attention updates (no timer), and the menu is
/// rebuilt each time it opens, so names and states are always current.
@MainActor
final class AttentionStatusItem: NSObject, NSMenuDelegate {
    static let shared = AttentionStatusItem()

    private var store: SessionStore?
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    func start(store: SessionStore) {
        guard self.store == nil else { return }
        self.store = store
        // Both publishers hand over the new value, which is what gets used (the setting is not stored yet when
        // @Published emits).
        store.settings.$showInMenuBar
            .removeDuplicates()
            .sink { [weak self] show in self?.setShown(show) }
            .store(in: &cancellables)
        store.waitingCountPublisher
            .removeDuplicates()
            .sink { [weak self] count in self?.update(count: count) }
            .store(in: &cancellables)
    }

    private func setShown(_ shown: Bool) {
        if shown, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "conch.waiting"
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            item.menu = menu
            item.button?.image = Self.icon
            item.button?.imagePosition = .imageLeading
            item.button?.setAccessibilityLabel(ConchInfo.appName)
            statusItem = item
            update(count: store?.waitingCountPublisher.value ?? 0)
        } else if !shown, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func update(count: Int) {
        guard let button = statusItem?.button else { return }
        button.title = count > 0 ? String(count) : ""
        button.toolTip = "\(ConchInfo.appName): " + Self.waitingSummary(count)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let store else { return }
        Self.populate(menu, store: store, target: self)
    }

    /// Fills the menu: one item per waiting session in jump order, then Jump to Next Waiting and Show Conch.
    /// Static so the smoke test can check it without putting an item in the menu bar.
    static func populate(_ menu: NSMenu, store: SessionStore, target: AttentionStatusItem) {
        menu.removeAllItems()
        let waiting = store.waitingSessions
        if waiting.isEmpty {
            let none = NSMenuItem(title: "Nothing waiting", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        let projects = projectNames(store)
        for session in waiting {
            let item = NSMenuItem(title: session.displayName, action: #selector(AttentionStatusItem.selectSession(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = session.id
            let state: String
            if case .needsInput(let message) = session.attention {
                state = "Waiting"
                item.image = stateImage("circle.fill", colors: [.systemOrange], pointSize: 8)
                item.toolTip = message
            } else {
                state = "Finished"
                item.image = stateImage("checkmark.circle.fill", colors: [.white, .systemGreen], pointSize: 12)
            }
            let place = projects[session.id].map { "\(state) in \($0)" } ?? state
            if #available(macOS 14.4, *) {
                item.subtitle = place
            } else {
                item.title = "\(session.displayName) (\(place))"
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let jump = NSMenuItem(title: "Jump to Next Waiting", action: #selector(AttentionStatusItem.jumpToNext(_:)), keyEquivalent: "")
        jump.target = target
        jump.isEnabled = !waiting.isEmpty
        menu.addItem(jump)
        let show = NSMenuItem(title: "Show \(ConchInfo.appName)", action: #selector(AttentionStatusItem.showConch(_:)), keyEquivalent: "")
        show.target = target
        menu.addItem(show)
    }

    static func waitingSummary(_ count: Int) -> String {
        switch count {
        case 0: return "nothing waiting"
        case 1: return "1 session waiting"
        default: return "\(count) sessions waiting"
        }
    }

    // MARK: Actions

    @objc private func selectSession(_ sender: NSMenuItem) {
        guard let store, let id = sender.representedObject as? UUID, let session = store.session(withID: id) else {
            return
        }
        AttentionJump.show(session, store: store)
    }

    @objc private func jumpToNext(_ sender: Any?) {
        AttentionJump.next(store: store ?? .shared)
    }

    @objc private func showConch(_ sender: Any?) {
        AppActions.showMainWindow()
    }

    // MARK: Private

    /// Project folder name per session, the same names the sidebar section headers show (Older sessions included).
    private static func projectNames(_ store: SessionStore) -> [UUID: String] {
        var names: [UUID: String] = [:]
        for group in store.groups {
            let name = store.project(of: group).name
            for session in group.sessions { names[session.id] = name }
        }
        return names
    }

    /// Drawn centred on one canvas size, so the small dot and the larger check leave the titles aligned.
    /// `colors` fills the symbol's layers in order (for checkmark.circle.fill: the check, then the circle).
    private static func stateImage(_ symbol: String, colors: [NSColor], pointSize: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return nil
        }
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { canvas in
            let size = glyph.size
            glyph.draw(in: NSRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                                  width: size.width, height: size.height))
            return true
        }
    }

    private static let icon: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = (NSImage(systemSymbolName: "fossil.shell", accessibilityDescription: ConchInfo.appName)
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: ConchInfo.appName))?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }()
}
