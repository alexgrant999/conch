import AppKit

// Owner: codex builder (feature/codex).

extension AppDelegate {
    /// New Codex Session, for the Session menu's new-session group.
    func addCodexMenuItems(to menu: NSMenu) {
        let item = NSMenuItem(title: "New Codex Session", action: #selector(CodexMenuTarget.newCodex(_:)), keyEquivalent: "")
        item.target = CodexMenuTarget.shared
        menu.addItem(item)
    }

    /// Ask Codex to Review on a Claude session, Ask Claude to Review on a Codex session.
    func addReviewMenuItems(to menu: NSMenu) {
        let item = NSMenuItem(title: "Ask Codex to Review", action: #selector(CodexMenuTarget.requestReview(_:)), keyEquivalent: "")
        item.target = CodexMenuTarget.shared
        menu.addItem(item)
    }
}

/// Menu items hold their target weakly, so it lives on as a singleton.
@MainActor
final class CodexMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = CodexMenuTarget()

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(requestReview(_:)) {
            let session = reviewableSession()
            let reviewer = session.flatMap(ReviewActions.reviewerKind(for:)) ?? .codex
            menuItem.title = "Ask \(ReviewActions.agentName(reviewer)) to Review"
            return session.map(ReviewActions.canRequest) ?? false
        }
        return true
    }

    @objc func newCodex(_ sender: Any?) {
        AppActions.showMainWindow()
        SessionStore.shared.newCodex()
    }

    @objc func requestReview(_ sender: Any?) {
        reviewableSession().map(ReviewActions.requestReview(of:))
    }

    private func reviewableSession() -> TerminalSession? {
        guard let window = AppActions.mainWindow, window.isVisible, !window.isMiniaturized,
              let session = SessionStore.shared.activeSession, ReviewActions.reviewerKind(for: session) != nil else { return nil }
        return session
    }
}
