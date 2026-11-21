import AppKit

// Owner: layouts builder (feature/layouts).

extension AppDelegate {
    /// Adds this feature's items to the menu passed in. Give each item its own target object (in this file)
    /// with a validateMenuItem, so AppDelegate.swift needs no changes.
    func addLayoutMenuItems(to menu: NSMenu) {
        let target = LayoutMenuTarget.shared
        menu.addItem(.separator())
        for (title, action) in [
            ("Set Startup Command…", #selector(LayoutMenuTarget.setStartupCommand(_:))),
            ("Save Layout for This Project", #selector(LayoutMenuTarget.saveLayout(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
    }
}

/// Menu items hold their target weakly, so this lives for the whole run.
@MainActor
private final class LayoutMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = LayoutMenuTarget()

    private var store: SessionStore { SessionStore.shared }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Same rule as the other Session items: nothing acts on a session in a hidden or minimized window.
        guard let window = AppActions.mainWindow, window.isVisible, !window.isMiniaturized else { return false }
        switch menuItem.action {
        case #selector(setStartupCommand(_:)):
            return store.activeSession?.spec.kind == .shell
        case #selector(saveLayout(_:)):
            return store.selectedGroup.map(LayoutActions.canSaveLayout) ?? false
        default:
            return true
        }
    }

    @objc func setStartupCommand(_ sender: Any?) {
        guard let session = store.activeSession else { return }
        LayoutActions.editStartupCommand(for: session)
    }

    @objc func saveLayout(_ sender: Any?) {
        LayoutActions.saveLayoutForSelectedGroup()
    }
}
