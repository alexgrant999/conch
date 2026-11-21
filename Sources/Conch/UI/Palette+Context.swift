import SwiftUI

// Owner: context builder (feature/context).

extension PaletteModel {
    /// Command palette items for context actions (compact, clear, hand off). Only while the active session is a
    /// Claude session at its prompt, the same rule as the Session menu.
    func contextCommands() -> [PaletteItem] {
        guard let session = ContextActions.actionableSession() else { return [] }
        let usage = session.context.map { "Context \(ContextLevel.percentText($0.usedPercent))" } ?? "Context not reported yet"
        let tint = SessionGlyph.claudeOrange

        // The palette can stay open while Claude starts a turn or a permission prompt appears, so check again.
        func item(_ title: String, _ symbol: String, detail: String, action: @escaping (TerminalSession) -> Void) -> PaletteItem {
            PaletteItem(id: "cmd:\(title)", symbol: symbol, tint: tint, title: title, detail: detail,
                        primary: { ContextActions.canAct(on: session) ? action(session) : Toast.show(ContextActions.busyMessage) })
        }

        return [
            item("Compact", "arrow.down.right.and.arrow.up.left", detail: usage, action: ContextActions.compact),
            item("Compact With Focus…", "scope", detail: usage, action: ContextActions.compactWithFocus),
            item("Clear Conversation…", "arrow.counterclockwise", detail: usage, action: ContextActions.clear),
            item("Hand Off to New Session", "arrowshape.turn.up.right", detail: "Writes \(ContextActions.handoffNote), then opens a new session",
                 action: ContextActions.handOff),
        ]
    }
}
