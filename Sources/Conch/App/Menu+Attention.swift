import AppKit

// Owner: attention builder (feature/attention).

extension AppDelegate {
    /// Adds this feature's items to the menu passed in. Give each item its own target object (in this file)
    /// with a validateMenuItem, so AppDelegate.swift needs no changes.
    func addAttentionMenuItems(to menu: NSMenu) {
        let jump = item("Jump to Next Waiting", #selector(AttentionJump.jumpToNextWaiting(_:)), "j")
        jump.target = AttentionJump.shared
        menu.addItem(jump)
    }

    /// Starts the menu bar item after restore.
    func startAttentionStatusItem() {
        AttentionStatusItem.shared.start(store: .shared)
    }
}

/// Jumping to sessions that need you. Cmd+J, the command palette and the menu bar item all come through here.
@MainActor
final class AttentionJump: NSObject, NSMenuItemValidation {
    /// Menu items hold their target weakly.
    static let shared = AttentionJump()
    static let nothingWaitingMessage = "Nothing needs you right now"

    /// Shows the next session in `SessionStore.waitingSessions` order, or says so over the window when nothing is
    /// waiting (a beep alone read as Cmd+J doing nothing).
    /// Showing a session clears its attention, so calling this again moves on to the next one.
    @discardableResult
    static func next(store: SessionStore) -> TerminalSession? {
        guard let session = store.selectNextWaiting() else {
            Toast.show(nothingWaitingMessage)
            return nil
        }
        AppActions.showMainWindow()
        return session
    }

    /// Selects the session and brings the main window forward.
    static func show(_ session: TerminalSession, store: SessionStore) {
        store.select(session)
        AppActions.showMainWindow()
    }

    @objc func jumpToNextWaiting(_ sender: Any?) {
        Self.next(store: .shared)
    }

    /// Enabled with nothing waiting so Cmd+J beeps instead of falling through to the terminal. Disabled while an
    /// alert or sheet is up, so a jump cannot change the selection under a close confirmation.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        NSApp.modalWindow == nil && AppActions.mainWindow?.attachedSheet == nil
    }
}
