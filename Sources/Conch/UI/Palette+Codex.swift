import SwiftUI

// Owner: codex builder (feature/codex).

extension PaletteModel {
    func codexCommands() -> [PaletteItem] {
        [PaletteItem(id: "cmd:New Codex Session", symbol: SessionGlyph.symbol(for: .codex), tint: SessionGlyph.codexGreen,
                     title: "New Codex Session", primary: {
                         AppActions.showMainWindow()
                         SessionStore.shared.newCodex()
                     })]
    }

    /// "Ask Codex to Review" on a Claude session, "Ask Claude to Review" on a Codex session, when it can be asked.
    func reviewCommands() -> [PaletteItem] {
        guard let session = SessionStore.shared.activeSession, let reviewer = ReviewActions.reviewerKind(for: session),
              ReviewActions.canRequest(session) else { return [] }
        let name = ReviewActions.agentName(reviewer)
        return [PaletteItem(id: "cmd:review", symbol: "checkmark.bubble", tint: SessionGlyph.tint(for: reviewer),
                            title: "Ask \(name) to Review", detail: session.displayName,
                            primary: { ReviewActions.requestReview(of: session) })]
    }
}
