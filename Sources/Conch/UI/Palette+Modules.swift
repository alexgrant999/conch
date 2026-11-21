import SwiftUI

// Owner: modules builder (feature/modules-section).

extension PaletteModel {
    /// Command palette items: the Modules window, then "<name> module" for each module.
    func moduleCommands() -> [PaletteItem] {
        let window = ModulesWindowController.shared
        var items = [
            PaletteItem(id: "cmd:Modules", symbol: "puzzlepiece.extension", title: "Modules", hint: "⇧⌘M",
                        primary: { window.present() }),
        ]
        items += ModuleLibrary.shared.modules.map { moduleItem($0, hint: nil) }
        return items
    }

    /// Quick Open items for modules whose name matches `q`, listed after the folders and projects. Only while
    /// typing, so an empty Quick Open stays about sessions. The name only: matching "<name> module" would put every
    /// module above the modules folder itself for a query like "mod".
    func moduleItems(query q: String) -> [PaletteItem] {
        guard !q.isEmpty else { return [] }
        var hits: [(score: Int, order: Int, item: PaletteItem)] = []
        for (order, module) in ModuleLibrary.shared.modules.enumerated() {
            guard let match = FuzzyMatcher.match(q, in: module.name) else { continue }
            var item = moduleItem(module, hint: "↩ Show")
            // The title starts with the name, so the positions carry over.
            item.titleMatches = match.positions
            hits.append((match.score, order, item))
        }
        return Self.ranked(hits)
    }

    private func moduleItem(_ module: ModuleInfo, hint: String?) -> PaletteItem {
        let id = module.id
        return PaletteItem(id: "module:\(id)", symbol: "puzzlepiece.extension", title: "\(module.name) module",
                           detail: ModulesText.summary(of: module), hint: hint,
                           primary: { ModulesWindowController.shared.present(selecting: id) })
    }
}
