import Foundation

/// Case-insensitive subsequence matching for the command palette.
/// Scores are only comparable between candidates matched against the same query. Higher is better.
enum FuzzyMatcher {
    struct Match: Equatable {
        let score: Int
        /// Character offsets in the candidate that matched the query, ascending.
        let positions: [Int]
    }

    static let prefixBonus = 15
    static let wordStartBonus = 6
    static let consecutiveBonus = 10
    static let gapStartPenalty = 4
    static let gapExtensionPenalty = 2
    static let maxLeadingPenalty = 6

    /// nil when the query (whitespace ignored) is not a subsequence of the candidate.
    /// An empty query matches everything with score 0.
    static func match(_ query: String, in candidate: String) -> Match? {
        let needle = query.filter { !$0.isWhitespace }.map { $0.lowercased() }
        guard !needle.isEmpty else { return Match(score: 0, positions: []) }

        let original = Array(candidate)
        let hay = original.map { $0.lowercased() }
        let n = hay.count
        let m = needle.count
        guard m <= n else { return nil }

        var found = 0
        for ch in hay where found < m && ch == needle[found] { found += 1 }
        guard found == m else { return nil }

        // Best alignment, not the greedy one: "ac" in "alpine-acorn" should take the "ac" of "acorn".
        // score[j][i] is the best score with needle[j] matched at hay[i]. Gaps cost an affine penalty,
        // tracked as a running best so the whole thing stays O(n * m).
        let none = Int.min / 4
        var score = [[Int]](repeating: [Int](repeating: none, count: n), count: m)
        var from = [[Int]](repeating: [Int](repeating: -1, count: n), count: m)
        let bonus = (0..<n).map { i in
            i == 0 ? prefixBonus : (isWordStart(original, i) ? wordStartBonus : 0)
        }

        for i in 0..<n where hay[i] == needle[0] {
            score[0][i] = bonus[i] - min(i, maxLeadingPenalty)
        }

        if m > 1 {
            for j in 1..<m {
                var gapBest = none
                var gapFrom = -1
                for i in 1..<n {
                    if i >= 2 {
                        let decayed = gapBest == none ? none : gapBest - gapExtensionPenalty
                        let source = score[j - 1][i - 2]
                        let opened = source == none ? none : source - gapStartPenalty
                        if opened != none && opened >= decayed {
                            gapBest = opened
                            gapFrom = i - 2
                        } else {
                            gapBest = decayed
                        }
                    }
                    guard hay[i] == needle[j] else { continue }
                    var best = none
                    var bestFrom = -1
                    let previous = score[j - 1][i - 1]
                    if previous != none {
                        best = previous + consecutiveBonus + bonus[i]
                        bestFrom = i - 1
                    }
                    if gapBest != none && gapBest + bonus[i] > best {
                        best = gapBest + bonus[i]
                        bestFrom = gapFrom
                    }
                    score[j][i] = best
                    from[j][i] = bestFrom
                }
            }
        }

        var best = none
        var end = -1
        for i in 0..<n where score[m - 1][i] != none && score[m - 1][i] > best {
            best = score[m - 1][i]
            end = i
        }
        guard end >= 0 else { return nil }

        var positions = [Int](repeating: 0, count: m)
        var cursor = end
        for j in stride(from: m - 1, through: 0, by: -1) {
            positions[j] = cursor
            cursor = from[j][cursor]
        }

        // Mild preference for shorter candidates, so "play" ranks "playday" above "playday-archive".
        return Match(score: best - (n - m) / 4, positions: positions)
    }

    private static func isWordStart(_ chars: [Character], _ i: Int) -> Bool {
        let previous = chars[i - 1]
        let current = chars[i]
        let previousIsWord = previous.isLetter || previous.isNumber
        if !previousIsWord { return current.isLetter || current.isNumber }
        if previous.isLowercase && current.isUppercase { return true }
        return previous.isLetter && current.isNumber
    }
}
