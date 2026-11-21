import SwiftUI

// Owner: layouts builder (feature/layouts).

extension PaletteModel {
    /// Quick Open items for saved project layouts matching `q`.
    func layoutItems(query q: String) -> [PaletteItem] {
        var hits: [(score: Int, order: Int, item: PaletteItem)] = []
        for (order, layout) in LayoutStore.shared.layouts.enumerated() {
            let title = LayoutActions.title(of: layout)
            let score: Int
            var positions: [Int] = []
            if let match = FuzzyMatcher.match(q, in: title) {
                score = match.score
                positions = match.positions
            } else if let match = FuzzyMatcher.match(q, in: layout.root.abbreviatingHome) {
                score = match.score - 15
            } else {
                continue
            }
            hits.append((score, order, PaletteItem(
                id: "layout:\(layout.id.uuidString)", symbol: "rectangle.split.2x1",
                title: title, titleMatches: positions, detail: LayoutActions.summary(of: layout.panes),
                hint: "↩ Open  ⌘↩ Delete",
                primary: { LayoutActions.open(layout) },
                secondary: { LayoutActions.confirmDelete(layout) }
            )))
        }
        return Self.ranked(hits, ordered: q.isEmpty)
    }

    /// Command palette items for layouts and startup commands.
    func layoutCommands() -> [PaletteItem] {
        var items: [PaletteItem] = []
        if let active = store.activeSession, active.spec.kind == .shell {
            items.append(PaletteItem(
                id: "cmd:Set Startup Command…", symbol: "play.rectangle", title: "Set Startup Command…",
                detail: active.spec.command ?? active.displayName,
                primary: { LayoutActions.editStartupCommand(for: active) }
            ))
        }
        if let group = store.selectedGroup, LayoutActions.canSaveLayout(group) {
            items.append(PaletteItem(
                id: "cmd:Save Layout for This Project", symbol: "rectangle.split.2x1",
                title: "Save Layout for This Project", detail: store.layoutSection(of: group)?.name,
                primary: { LayoutActions.saveLayoutForSelectedGroup() }
            ))
        }
        return items
    }
}
