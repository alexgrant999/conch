import SwiftUI

// Owner: recent conversations builder (feature/recent-conversations).

extension PaletteModel {
    static let recentConversationLimit = 8
    static let matchingConversationLimit = 15

    /// Quick Open items for recent Claude conversations (`conversations`), matching `q` (empty shows the newest).
    func recentConversationItems(query q: String) -> [PaletteItem] {
        guard !conversations.isEmpty else { return [] }
        let store = self.store

        var open = Set<UUID>()
        for session in store.allSessions {
            if let id = session.spec.claude?.sessionID { open.insert(id) }
            // After /clear or /resume the session is on a different conversation than the one it launched with.
            if let id = session.context?.claudeSessionID { open.insert(id) }
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        let now = Date()
        let limit = q.isEmpty ? Self.recentConversationLimit : Self.matchingConversationLimit

        var entries: [(score: Int, order: Int, item: PaletteItem)] = []
        for (order, conversation) in conversations.enumerated() where !open.contains(conversation.sessionID) {
            var score = 0
            var positions: [Int] = []
            if !q.isEmpty {
                let titleMatch = FuzzyMatcher.match(q, in: conversation.title)
                let folderScore = FuzzyMatcher.match(q, in: conversation.directory.lastPathComponentOrSelf).map { $0.score - 20 }
                if let titleMatch, titleMatch.score >= (folderScore ?? Int.min) {
                    score = titleMatch.score
                    positions = titleMatch.positions
                } else if let folderScore {
                    score = folderScore
                } else {
                    continue
                }
            }

            let sessionID = conversation.sessionID
            let directory = conversation.directory
            let age = formatter.localizedString(for: min(conversation.modified, now), relativeTo: now)
            entries.append((score, order, PaletteItem(
                id: "conversation:\(sessionID.uuidString)",
                symbol: "bubble.left", tint: SessionGlyph.tint(for: .claude),
                title: conversation.title, titleMatches: positions,
                detail: "\(directory.abbreviatingHome) · \(age)", hint: "↩ Resume",
                primary: { store.resumeClaude(sessionID: sessionID, in: directory) }
            )))
            if q.isEmpty, entries.count == limit { break }
        }
        return Array(Self.ranked(entries, ordered: q.isEmpty).prefix(limit))
    }
}
