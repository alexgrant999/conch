import SwiftUI

// Owner: attention builder (feature/attention).

extension PaletteModel {
    /// Command palette items for jumping to sessions that need you.
    func attentionCommands() -> [PaletteItem] {
        let store = self.store
        let count = store.attentionCount
        return [
            PaletteItem(id: "cmd:Jump to Next Waiting", symbol: count > 0 ? "bell.badge" : "bell",
                        title: "Jump to Next Waiting", detail: count > 0 ? "\(count) waiting" : "Nothing waiting",
                        hint: "⌘J", primary: { AttentionJump.next(store: store) }),
        ]
    }
}
