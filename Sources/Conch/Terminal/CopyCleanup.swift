import Foundation

/// Turns a selection copied out of a Claude Code session back into the text Claude wrote: the response marker and
/// the indent go, trailing spaces go, and lines Claude Code broke at the terminal's edge are joined again.
///
/// Claude Code wraps with real newlines, so the terminal cannot tell a wrapped line from a short one. A line counts
/// as wrapped when the next line's first word would not have fit after it.
enum CopyCleanup {
    /// How far short of the terminal's width Claude Code may wrap, when the selection has no line that long.
    private static let wrapSlack = 8

    static func clean(_ raw: String, columns: Int) -> String {
        var lines = raw.components(separatedBy: "\n").map { line -> String in
            var line = String(line.reversed().drop { $0 == " " || $0 == "\t" || $0 == "\r" }.reversed())
            if let first = line.first, isResponseMarker(first), line.dropFirst().first == " " {
                line = "  " + line.dropFirst(2)
            }
            return line
        }
        let widths = lines.map(displayWidth)

        // The first line may start partway along its row, so the others decide the indent.
        let filled = lines.indices.filter { !lines[$0].isEmpty }
        let indentSources = filled.count > 1 ? Array(filled.dropFirst()) : filled
        let indent = indentSources.map { leadingSpaces(lines[$0]) }.min() ?? 0
        lines = lines.map { String($0.dropFirst(min(indent, leadingSpaces($0)))) }

        let limit = max(widths.max() ?? 0, columns - wrapSlack)
        var result: [String] = []
        for index in lines.indices {
            let line = lines[index]
            guard index > 0, let previous = result.last, !line.isEmpty, !lines[index - 1].isEmpty,
                  !startsBlock(line), !hasBoxDrawing(lines[index - 1]) else {
                result.append(line)
                continue
            }
            let text = line.drop { $0 == " " }
            let firstWord = text.prefix { $0 != " " }
            guard widths[index - 1] + 1 + displayWidth(String(firstWord)) > limit else {
                result.append(line)
                continue
            }
            // A token longer than the row (a URL, a path) is cut mid-word and fills its row to the edge.
            let previousText = lines[index - 1].drop { $0 == " " }
            let cutMidWord = widths[index - 1] >= limit && !previousText.contains(" ")
            result[result.count - 1] = previous + (cutMidWord ? "" : " ") + text
        }
        return result.joined(separator: "\n")
    }

    private static func isResponseMarker(_ character: Character) -> Bool {
        character == "\u{23FA}" || character == "\u{25CF}"
    }

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    /// List items, headings, quotes, table rows and tool output start their own line however full the one above is.
    private static func startsBlock(_ line: String) -> Bool {
        let text = line.drop { $0 == " " }
        guard let first = text.first else { return false }
        if isResponseMarker(first) || first == "\u{23BF}" || first == "\u{276F}" || first == "#" || first == ">" || first == "|" { return true }
        if hasBoxDrawing(String(first)) { return true }
        if "-*+\u{2022}".contains(first) { return text.dropFirst().first == " " }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty {
            let rest = text.dropFirst(digits.count)
            return (rest.first == "." || rest.first == ")") && rest.dropFirst().first == " "
        }
        return false
    }

    private static func hasBoxDrawing(_ line: String) -> Bool {
        line.unicodeScalars.contains { (0x2500...0x257F).contains($0.value) }
    }

    /// Terminal cells the line takes: two for East Asian wide characters and emoji, one for the rest.
    private static func displayWidth(_ line: String) -> Int {
        line.reduce(0) { total, character in
            guard let scalar = character.unicodeScalars.first else { return total }
            let wide: Bool
            switch scalar.value {
            case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
                 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF:
                wide = true
            default:
                wide = false
            }
            return total + (wide ? 2 : 1)
        }
    }
}
