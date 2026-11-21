import AppKit

// Owner: context builder (feature/context).

extension AppDelegate {
    /// Adds this feature's items to the menu passed in. Give each item its own target object (in this file)
    /// with a validateMenuItem, so AppDelegate.swift needs no changes.
    func addContextMenuItems(to menu: NSMenu) {
        menu.addItem(.separator())
        let target = ContextMenuTarget.shared
        for (title, action) in [
            ("Compact", #selector(ContextMenuTarget.compact(_:))),
            ("Compact With Focus…", #selector(ContextMenuTarget.compactWithFocus(_:))),
            ("Clear Conversation…", #selector(ContextMenuTarget.clearConversation(_:))),
            ("Hand Off to New Session", #selector(ContextMenuTarget.handOff(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
    }

    /// Starts watching context use for Claude sessions after restore.
    func startContextMonitor() {
        ContextMonitor.shared.start()
    }
}

/// Menu items hold their target weakly, so it lives on as a singleton.
@MainActor
final class ContextMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = ContextMenuTarget()

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        ContextActions.actionableSession() != nil
    }

    @objc func compact(_ sender: Any?) {
        ContextActions.actionableSession().map(ContextActions.compact)
    }

    @objc func compactWithFocus(_ sender: Any?) {
        ContextActions.actionableSession().map(ContextActions.compactWithFocus)
    }

    @objc func clearConversation(_ sender: Any?) {
        ContextActions.actionableSession().map(ContextActions.clear)
    }

    @objc func handOff(_ sender: Any?) {
        ContextActions.actionableSession().map(ContextActions.handOff)
    }
}
