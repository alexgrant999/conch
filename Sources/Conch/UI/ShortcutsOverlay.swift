import AppKit
import SwiftUI

/// One row of the shortcuts sheet.
struct ShortcutEntry: Identifiable, Equatable {
    let keys: String
    let title: String
    var id: String { keys + title }
}

struct ShortcutGroup: Identifiable, Equatable {
    let title: String
    let entries: [ShortcutEntry]
    var id: String { title }
}

/// A sheet of every keyboard shortcut, over the main window (Cmd+/). The list is read from the menu bar each time it
/// opens, so it can never drift from what the keys really do. Any key or click closes it.
@MainActor
enum ShortcutsOverlay {
    private static var panel: NSPanel?
    private static var monitor: Any?

    static var isShown: Bool { panel != nil }

    /// PNG of the sheet as drawn, for the smoke test to save. nil when it is not showing.
    static func snapshot() -> Data? {
        guard let view = panel?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    static func toggle() {
        if isShown { dismiss() } else { show() }
    }

    static func show() {
        guard let window = AppActions.mainWindow, window.isVisible, !window.isMiniaturized else {
            NSSound.beep()
            return
        }
        dismiss()
        let host = NSHostingView(rootView: ShortcutsSheet(groups: groups()))
        let size = host.fittingSize
        let sheet = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        sheet.isOpaque = false
        sheet.backgroundColor = .clear
        sheet.hasShadow = true
        sheet.isReleasedWhenClosed = false
        sheet.appearance = window.effectiveAppearance
        sheet.contentView = host
        sheet.setFrameOrigin(NSPoint(x: window.frame.midX - size.width / 2, y: window.frame.midY - size.height / 2))
        window.addChildWindow(sheet, ordered: .above)
        panel = sheet
        // Escape is swallowed. Any other key or click closes the sheet and still does what it normally does.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            let isKey = event.type == .keyDown
            // Cmd+/ reaches the menu item, which toggles the sheet shut.
            if isKey, event.charactersIgnoringModifiers == "/", event.modifierFlags.contains(.command) { return event }
            MainActor.assumeIsolated { dismiss() }
            return isKey && event.keyCode == 53 ? nil : event
        }
    }

    static func dismiss() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard let sheet = panel else { return }
        sheet.parent?.removeChildWindow(sheet)
        sheet.orderOut(nil)
        panel = nil
    }

    // MARK: - Reading the menus

    /// Shortcuts by menu, then the few that are not menu items.
    static func groups() -> [ShortcutGroup] {
        var result: [ShortcutGroup] = []
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            let entries = collapseDigits(entries(in: menu))
            if !entries.isEmpty { result.append(ShortcutGroup(title: menu.title, entries: entries)) }
        }
        result.append(ShortcutGroup(title: "Also", entries: [
            ShortcutEntry(keys: "⌃⇥", title: "Next session"),
            ShortcutEntry(keys: "⌃⇧⇥", title: "Previous session"),
            ShortcutEntry(keys: "⇧↩", title: "New line in Claude's prompt"),
        ]))
        return result
    }

    private static func entries(in menu: NSMenu) -> [ShortcutEntry] {
        menu.items.flatMap { item -> [ShortcutEntry] in
            if let submenu = item.submenu { return entries(in: submenu) }
            // macOS adds Emoji & Symbols itself and reports a key for it that is not the real one.
            guard !item.isHidden, !item.isAlternate, !item.keyEquivalent.isEmpty,
                  item.action != #selector(NSApplication.orderFrontCharacterPalette(_:)) else { return [] }
            return [ShortcutEntry(keys: keys(for: item), title: item.title)]
        }
    }

    /// "⌘1" through "⌘9" as one row.
    private static func collapseDigits(_ entries: [ShortcutEntry]) -> [ShortcutEntry] {
        let digits = entries.filter { $0.keys.count == 2 && $0.keys.hasPrefix("⌘") && ("1"..."9").contains(String($0.keys.last!)) }
        guard digits.count > 2, let first = entries.firstIndex(of: digits[0]) else { return entries }
        var kept = entries.filter { !digits.contains($0) }
        kept.insert(ShortcutEntry(keys: "⌘1 to ⌘9", title: "Jump to a session"), at: min(first, kept.count))
        return kept
    }

    static func keys(for item: NSMenuItem) -> String {
        var flags = item.keyEquivalentModifierMask
        var key = item.keyEquivalent
        // An uppercase letter as the key equivalent means Shift, which AppKit does not list in the mask.
        if key.count == 1, key != key.lowercased() { flags.insert(.shift) }
        if let name = specialKeys[key] { key = name } else { key = key.uppercased() }
        var text = ""
        // macOS moves Enter Full Screen to the Globe key on recent systems.
        if flags.contains(.function) { text += "fn " }
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }

    private static let specialKeys: [String: String] = [
        "\r": "↩", "\t": "⇥", "\u{1b}": "⎋", " ": "Space", "\u{8}": "⌫", "\u{7f}": "⌫",
        String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑", String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
        String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←", String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
    ]
}

private struct ShortcutsSheet: View {
    let groups: [ShortcutGroup]

    var body: some View {
        // Two columns of roughly equal height.
        let half = (groups.reduce(0) { $0 + $1.entries.count + 2 } + 1) / 2
        let split = splitIndex(half)
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts").font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top, spacing: 28) {
                column(Array(groups[..<split]))
                column(Array(groups[split...]))
            }
            Text("Press any key to close").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .fixedSize()
    }

    private func splitIndex(_ half: Int) -> Int {
        var count = 0
        for (index, group) in groups.enumerated() {
            count += group.entries.count + 2
            if count >= half { return min(index + 1, groups.count) }
        }
        return groups.count
    }

    private func column(_ groups: [ShortcutGroup]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(group.entries) { entry in
                        HStack(spacing: 10) {
                            Text(entry.keys)
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .frame(width: 74, alignment: .leading)
                            Text(entry.title).font(.system(size: 12))
                        }
                    }
                }
            }
        }
    }
}
