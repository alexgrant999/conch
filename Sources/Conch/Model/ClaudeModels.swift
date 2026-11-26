import Foundation

// Owner: model builder (feature/model).

/// One entry in the model menus. `model` is what Conch passes to `--model` and types after `/model`: a family alias
/// ("opus", the latest Opus Claude Code knows) or a specific model id ("claude-opus-4-8").
struct ClaudeModelChoice: Identifiable, Equatable {
    let model: String
    let name: String
    let family: String
    var id: String { model }
    var isLatest: Bool { model == family }
}

struct ClaudeModelFamily: Identifiable, Equatable {
    let alias: String
    let name: String
    /// Specific models, newest first.
    let versions: [ClaudeModelChoice]
    var id: String { alias }
    var latest: ClaudeModelChoice { ClaudeModelChoice(model: alias, name: "Latest \(name)", family: alias) }
}

enum ClaudeModels {
    /// The models Anthropic lists as available on the Claude API (models overview, November 2026), minus the retired
    /// and the limited-access ones. "Other Model…" covers anything else Claude Code accepts.
    static let families: [ClaudeModelFamily] = [
        family("fable", "Fable", [("claude-fable-5-2", "5.2"), ("claude-fable-5-1", "5.1"), ("claude-fable-5", "5")]),
        family("opus", "Opus", [("claude-opus-5-5", "5.5"), ("claude-opus-5", "5"), ("claude-opus-4-8", "4.8"),
                                ("claude-opus-4-7", "4.7"), ("claude-opus-4-6", "4.6"), ("claude-opus-4-5", "4.5")]),
        family("sonnet", "Sonnet", [("claude-sonnet-5-5", "5.5"), ("claude-sonnet-5", "5"), ("claude-sonnet-4-6", "4.6"),
                                    ("claude-sonnet-4-5", "4.5")]),
        family("haiku", "Haiku", [("claude-haiku-5-5", "5.5"), ("claude-haiku-4-5", "4.5")]),
    ]

    /// Every family's Latest entry, then every specific model.
    static var all: [ClaudeModelChoice] {
        families.map(\.latest) + families.flatMap(\.versions)
    }

    /// The menu entry for a model as Conch stored it or Claude Code reported it. Dated ids
    /// ("claude-sonnet-4-5-20250929") and 1M context ids ("claude-opus-5-5[1m]") count as their model. nil for a
    /// model the menus do not list.
    static func choice(model: String?) -> ClaudeModelChoice? {
        guard var id = model?.lowercased(), !id.isEmpty else { return nil }
        if id.hasSuffix("[1m]") { id.removeLast(4) }
        return all.first { choice in
            guard id.hasPrefix(choice.model) else { return false }
            let rest = id.dropFirst(choice.model.count)
            return rest.isEmpty || (rest.count == 9 && rest.first == "-" && rest.dropFirst().allSatisfy(\.isNumber))
        }
    }

    /// The family of an alias, a model id or a display name: "opus", "claude-opus-4-8" and "Opus 5.5" are all Opus.
    static func family(of model: String?) -> ClaudeModelFamily? {
        guard let model = model?.lowercased(), !model.isEmpty else { return nil }
        return families.first { model.contains($0.alias) }
    }

    /// True for text that can go after `/model` and `--model`: one word of letters, digits and `-._:[]`.
    static func isValidModel(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 100 && !text.hasPrefix("-")
            && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-._:[]".unicodeScalars.contains($0) }
    }

    private static func family(_ alias: String, _ name: String, _ versions: [(String, String)]) -> ClaudeModelFamily {
        ClaudeModelFamily(alias: alias, name: name,
                          versions: versions.map { ClaudeModelChoice(model: $0.0, name: "\(name) \($0.1)", family: alias) })
    }
}
