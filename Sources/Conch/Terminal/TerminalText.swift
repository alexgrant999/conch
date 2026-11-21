import Foundation

// Owner: core agent. Pure parsing for titles, OSC 7 directories and OSC desktop notifications.

/// A desktop notification a program asked for (OSC 9, 99 or 777).
struct TerminalNotification: Equatable {
    var message: String?
}

enum TerminalText {
    static let maxTitleLength = 120
    static let maxMessageLength = 300

    /// Strips control and bidi formatting characters, then leading status glyphs (non-ASCII So, Sm, Braille,
    /// Dingbats) and whitespace, then caps the length. Empty means "no title".
    static func sanitizeTitle(_ raw: String) -> String {
        var scalars = raw.unicodeScalars.filter { !isControlOrBidi($0) }
        while let first = scalars.first, isLeadingGlyph(first) || first.properties.isWhitespace {
            scalars.removeFirst()
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxTitleLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The local path from an OSC 7 value (`file://host/path` or a bare path). nil for another host or garbage.
    static func directory(fromOSC7 value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("/") { return value }
        let scheme = "file://"
        guard value.lowercased().hasPrefix(scheme) else { return nil }
        let rest = value.dropFirst(scheme.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        guard isLocalHost(String(rest[..<slash])) else { return nil }
        let encodedPath = String(rest[slash...])
        let path = encodedPath.removingPercentEncoding ?? encodedPath
        return path.isEmpty ? nil : path
    }

    /// OSC 9 (iTerm2 style, minus ConEmu numeric subcommands such as `4;` progress) and OSC 777 (`notify;title;body`).
    /// OSC 99 needs state across chunks, see `KittyNotificationAssembler`.
    static func notification(code: Int, payload: [UInt8]) -> TerminalNotification? {
        let text = String(decoding: payload, as: UTF8.self)
        switch code {
        case 9:
            if text.range(of: "^[0-9]+(;|$)", options: .regularExpression) != nil { return nil }
            return TerminalNotification(message: cleanMessage(text))
        case 777:
            let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, parts[0] == "notify" else { return nil }
            let body = parts.count > 2 ? String(parts[2]) : ""
            return TerminalNotification(message: messageText(title: String(parts[1]), body: body))
        default:
            return nil
        }
    }

    /// The body when there is one, else the title. The title is usually the program name, which the notification
    /// already shows as the session name.
    static func messageText(title: String, body: String) -> String? {
        cleanMessage(body) ?? cleanMessage(title)
    }

    static func cleanMessage(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars.filter { !isControlOrBidi($0) }
        let text = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(maxMessageLength))
    }

    static func isLocalHost(_ host: String) -> Bool {
        func shortName(_ name: String) -> String {
            let name = name.lowercased()
            return name.hasSuffix(".local") ? String(name.dropLast(6)) : name
        }
        if host.isEmpty || host.caseInsensitiveCompare("localhost") == .orderedSame { return true }
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return false }
        let local = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return shortName(host) == shortName(local)
    }

    private static func isControlOrBidi(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control { return true }
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    /// ASCII is never a status glyph: "~" and "+" are category Sm, and shells put "~/project" in the title.
    private static func isLeadingGlyph(_ scalar: Unicode.Scalar) -> Bool {
        guard !scalar.isASCII else { return false }
        switch scalar.value {
        case 0x2700...0x27BF, 0x2800...0x28FF: return true
        // Variation selectors and the zero width joiner trail emoji glyphs.
        case 0xFE00...0xFE0F, 0x200D: return true
        default: break
        }
        switch scalar.properties.generalCategory {
        case .otherSymbol, .mathSymbol: return true
        default: return false
        }
    }
}

/// Collects OSC 99 (kitty desktop notification) chunks: `99;i=1:d=0:p=title;Hello`, then `99;i=1:p=body;World`.
struct KittyNotificationAssembler {
    private var id = ""
    private var title = ""
    private var body = ""

    /// Returns the notification once its last chunk (`d=1`, the default) arrives.
    mutating func consume(_ payload: [UInt8]) -> TerminalNotification? {
        let text = String(decoding: payload, as: UTF8.self)
        let parts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        var keys: [Substring: Substring] = [:]
        for pair in (parts.first ?? "").split(separator: ":") {
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if keyValue.count == 2 { keys[keyValue[0]] = keyValue[1] }
        }
        // Other payload types are queries, icons, buttons, close and alive reports.
        let kind = keys["p"] ?? "title"
        guard kind == "title" || kind == "body" else { return nil }

        var content = parts.count > 1 ? String(parts[1]) : ""
        if keys["e"] == "1" {
            content = Data(base64Encoded: content, options: .ignoreUnknownCharacters)
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
        }

        let chunkID = String(keys["i"] ?? "")
        if chunkID != id {
            id = chunkID
            title = ""
            body = ""
        }
        if kind == "title" { title += content } else { body += content }
        guard keys["d"] != "0" else { return nil }

        let notification = TerminalNotification(message: TerminalText.messageText(title: title, body: body))
        id = ""
        title = ""
        body = ""
        return notification
    }
}
