import SwiftUI

// Owner: worktree builder (feature/worktree).

extension PaletteModel {
    /// Command palette items for worktree sessions.
    func worktreeCommands() -> [PaletteItem] {
        guard let root = store.worktreeCapableRoot() else { return [] }
        return [
            PaletteItem(id: "cmd:New Claude in Worktree", symbol: "arrow.triangle.branch",
                        tint: SessionGlyph.claudeOrange, title: "New Claude in Worktree",
                        detail: root.lastPathComponentOrSelf, hint: "⌥⌘N",
                        primary: { AppActions.newClaudeInWorktree() }),
        ]
    }
}
