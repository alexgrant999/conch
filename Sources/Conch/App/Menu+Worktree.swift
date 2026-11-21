import AppKit

// Owner: worktree builder (feature/worktree).

extension AppDelegate {
    /// Adds this feature's items to the menu passed in. Give each item its own target object (in this file)
    /// with a validateMenuItem, so AppDelegate.swift needs no changes.
    func addWorktreeMenuItems(to menu: NSMenu) {
        let item = NSMenuItem(title: "New Claude in Worktree",
                              action: #selector(WorktreeMenuTarget.newClaudeInWorktree(_:)),
                              keyEquivalent: "n")
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = WorktreeMenuTarget.shared
        item.toolTip = "Claude in its own git worktree and branch, so it never edits the same files as another session"
        menu.addItem(item)
    }
}

extension AppActions {
    /// Cmd+Option+N. The menu item is disabled outside a usable repository, so a failure here is a race with the
    /// folder changing, or every worktree name for this minute taken.
    static func newClaudeInWorktree() {
        showMainWindow()
        if SessionStore.shared.newClaudeInWorktree() == nil {
            Toast.show("Could not start a worktree here")
        }
    }
}

/// Menu items keep a weak target, so the shared instance keeps this one alive.
@MainActor
final class WorktreeMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = WorktreeMenuTarget()

    @objc func newClaudeInWorktree(_ sender: Any?) {
        AppActions.newClaudeInWorktree()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        SessionStore.shared.worktreeCapableRoot() != nil
    }
}
