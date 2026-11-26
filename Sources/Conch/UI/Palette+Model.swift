import SwiftUI

// Owner: model builder (feature/model).

extension PaletteModel {
    /// "Switch Model to …" while the active session is a Claude session at its prompt, the same rule as the Session
    /// menu. The Latest entries always, the specific models and Other only once something is typed, so the full
    /// list does not crowd the empty palette.
    func modelCommands() -> [PaletteItem] {
        guard let session = ContextActions.actionableSession() else { return [] }
        let now = "Now \(ModelActions.label(for: session))"
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let choices = searching ? ClaudeModels.all : ClaudeModels.families.map(\.latest)
        var items = choices.filter { !ModelActions.isCurrent($0, for: session) }.map { choice in
            PaletteItem(id: "cmd:model:\(choice.model)", symbol: "cpu", tint: SessionGlyph.claudeOrange,
                        title: "Switch Model to \(choice.name)", detail: now,
                        primary: { ModelActions.choose(choice, for: session) })
        }
        if searching {
            items.append(PaletteItem(id: "cmd:model:other", symbol: "cpu", tint: SessionGlyph.claudeOrange,
                                     title: "Switch Model to Other…", detail: now,
                                     primary: { ModelActions.chooseOther(for: session) }))
        }
        return items
    }
}
