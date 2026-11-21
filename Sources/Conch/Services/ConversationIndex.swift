import Foundation

// Owner: recent conversations builder (feature/recent-conversations).

/// Claude Code conversations on disk, newest first, for Quick Open.
final class ConversationIndex: @unchecked Sendable {
    static let shared = ConversationIndex()

    static let cacheLifetime: TimeInterval = 60
    /// Newest transcripts parsed per build.
    static let parseLimit = 150
    /// Bytes read from the start of a transcript while looking for the first prompt. Pasted screenshots sit inline
    /// in that prompt as base64, so it can end a megabyte or more into the file.
    static let headBudget = 4 << 20
    /// Claude Code re-appends its custom-title and ai-title lines as a session goes on, so the latest one is near the
    /// end (never more than about 35 KB from it in real transcripts). The wide window is a fallback for big files.
    static let tailWindow = 128 << 10
    static let wideTailWindow = 1 << 20
    static let maxTitleLength = 60

    struct Transcript {
        let url: URL
        let sessionID: UUID
        let modified: Date
        let size: Int
    }

    enum HeadResult: Equatable {
        /// `title` is the first real prompt, used when the transcript has no custom or AI title.
        case conversation(directory: String, title: String)
        /// Started by `claude -p` or the Agent SDK (scheduled jobs), not something to resume by hand.
        case headless
        /// No real prompt within the budget yet.
        case noPrompt

        /// The head of a transcript never changes once written, so only `.noPrompt` can change later.
        var isFinal: Bool { self != .noPrompt }
    }

    /// The latest names Claude Code recorded: from /rename, and its own summary of the conversation.
    struct TailTitles: Equatable {
        var custom: String?
        var ai: String?

        /// Transcripts only grow, so a title from earlier stands until a later line replaces it.
        func updated(with newer: TailTitles) -> TailTitles {
            TailTitles(custom: newer.custom ?? custom, ai: newer.ai ?? ai)
        }
    }

    private struct CachedFile {
        let size: Int
        let modified: Date
        let head: HeadResult
        let titles: TailTitles
    }

    private let queue = DispatchQueue(label: "com.alexgrant.conch.conversation-index", qos: .userInitiated)
    // State below is only touched on `queue`.
    private var cache: (projects: String, built: Date, list: [ConversationSummary])?
    private var files: [String: CachedFile] = [:]
    private var lastReads = 0

    /// Calls `completion` on the main queue with the recent conversations, from cache when fresh.
    func refreshIfNeeded(_ completion: @escaping @MainActor ([ConversationSummary]) -> Void) {
        let projects = Self.projectsDirectory()
        queue.async { [self] in
            let list: [ConversationSummary]
            if let cache, cache.projects == projects.path, Date().timeIntervalSince(cache.built) < Self.cacheLifetime {
                list = cache.list
            } else {
                list = build(projects: projects)
                cache = (projects.path, Date(), list)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(list) }
            }
        }
    }

    /// Drops the 60 s list cache but keeps what is known per file, so the next refresh rebuilds. For the smoke test.
    func expireListCache() {
        queue.sync { cache = nil }
    }

    /// Transcripts the last build looked at again, because they were new or had changed since the build before.
    var filesReadByLastBuild: Int {
        queue.sync { lastReads }
    }

    static func projectsDirectory() -> URL {
        LaunchCommand.claudeConfigDirectory().appendingPathComponent("projects", isDirectory: true)
    }

    private func build(projects: URL) -> [ConversationSummary] {
        let transcripts = Array(Self.transcripts(in: projects).prefix(Self.parseLimit))
        var entries = [CachedFile?](repeating: nil, count: transcripts.count)
        var stale: [Int] = []
        for (index, file) in transcripts.enumerated() {
            if let cached = files[file.url.path], cached.size == file.size, cached.modified == file.modified {
                entries[index] = cached
            } else {
                stale.append(index)
            }
        }

        let previous = files
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: stale.count) { slot in
            let index = stale[slot]
            let entry = Self.read(transcripts[index], previous: previous[transcripts[index].url.path])
            lock.lock()
            entries[index] = entry
            lock.unlock()
        }

        let fileManager = FileManager.default
        var next: [String: CachedFile] = [:]
        var seen = Set<UUID>()
        var list: [ConversationSummary] = []
        for (file, entry) in zip(transcripts, entries) {
            guard let entry else { continue }
            next[file.url.path] = entry
            guard case let .conversation(directory, promptTitle) = entry.head else { continue }
            // Resuming from another folder is unreliable, so a conversation whose folder is gone is left out.
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue,
                  // The same id can sit in two project folders after a folder move. Keep the newer one.
                  seen.insert(file.sessionID).inserted else { continue }
            let title = entry.titles.custom ?? entry.titles.ai ?? promptTitle
            list.append(ConversationSummary(sessionID: file.sessionID, directory: directory, title: title, modified: file.modified))
        }
        files = next
        lastReads = stale.count
        return list
    }

    /// Reads what changed since `previous`: the head only until it is final, the tail titles only for conversations.
    private static func read(_ file: Transcript, previous: CachedFile?) -> CachedFile {
        let grew = previous.map { file.size >= $0.size } ?? false
        let head: HeadResult
        if let previous, grew, previous.head.isFinal {
            head = previous.head
        } else {
            head = readHead(of: file.url)
        }
        var titles = TailTitles()
        if case .conversation = head {
            let latest = readTailTitles(of: file.url, size: file.size)
            titles = grew ? (previous?.titles ?? TailTitles()).updated(with: latest) : latest
        }
        return CachedFile(size: file.size, modified: file.modified, head: head, titles: titles)
    }

    /// `<projects>/<encoded folder>/<uuid>.jsonl`, newest first. Subfolders hold subagent transcripts and are skipped.
    static func transcripts(in projects: URL) -> [Transcript] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let folders = try? fileManager.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles]) else { return [] }
        var files: [Transcript] = []
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let entries = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                     options: [.skipsHiddenFiles]) else { continue }
            for entry in entries where entry.pathExtension == "jsonl" {
                guard let sessionID = UUID(uuidString: entry.deletingPathExtension().lastPathComponent),
                      let values = try? entry.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate else { continue }
                files.append(Transcript(url: entry, sessionID: sessionID, modified: modified, size: values.fileSize ?? 0))
            }
        }
        return files.sorted { $0.modified > $1.modified }
    }

    // MARK: - Reading a transcript head

    private static let chunkSize = 64 << 10
    private static let userNeedle = Array("\"user\"".utf8)
    private static let cwdNeedle = Array("\"cwd\"".utf8)
    private static let customTitleNeedle = Array("\"custom-title\"".utf8)
    private static let aiTitleNeedle = Array("\"ai-title\"".utf8)

    /// The first `cwd` and the first real prompt, reading line by line and stopping as soon as both are known.
    static func readHead(of url: URL, budget: Int = headBudget) -> HeadResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .noPrompt }
        defer { try? handle.close() }

        var scanner = HeadScanner()
        var buffer: [UInt8] = []
        var scanFrom = 0
        var consumed = 0
        var atEnd = false
        while !atEnd, consumed < budget {
            guard let chunk = try? handle.read(upToCount: min(chunkSize, budget - consumed)), !chunk.isEmpty else {
                atEnd = true
                break
            }
            consumed += chunk.count
            buffer.append(contentsOf: chunk)

            var lineStart = 0
            while let newline = index(of: 0x0A, in: buffer, from: scanFrom) {
                if let result = scanner.feed(buffer[lineStart..<newline]) { return result }
                lineStart = newline + 1
                scanFrom = lineStart
            }
            buffer.removeSubrange(0..<lineStart)
            scanFrom = buffer.count
        }
        // A last line with no trailing newline is complete only when the file really ended.
        if atEnd, !buffer.isEmpty, let result = scanner.feed(buffer[...]) { return result }
        return .noPrompt
    }

    private struct HeadScanner {
        var directory: String?
        var sawUserLine = false

        mutating func feed(_ line: ArraySlice<UInt8>) -> HeadResult? {
            let mentionsUser = ConversationIndex.contains(ConversationIndex.userNeedle, in: line)
            let wantsDirectory = directory == nil && ConversationIndex.contains(ConversationIndex.cwdNeedle, in: line)
            guard mentionsUser || wantsDirectory, let object = ConversationIndex.object(from: line) else { return nil }
            if directory == nil, let cwd = object["cwd"] as? String, !cwd.isEmpty {
                directory = cwd
            }
            guard object["type"] as? String == "user" else { return nil }
            if !sawUserLine {
                sawUserLine = true
                if let entrypoint = object["entrypoint"] as? String, entrypoint.hasPrefix("sdk") { return .headless }
            }
            guard let text = ConversationIndex.promptText(object),
                  let title = ConversationIndex.title(fromPrompt: text) else { return nil }
            guard let directory else { return .headless }
            return .conversation(directory: directory, title: title)
        }
    }

    // MARK: - Reading the tail titles

    /// The latest custom-title and ai-title lines in the last `tailWindow` bytes, or the last `wideTailWindow` bytes
    /// of a big file when the short window has neither.
    static func readTailTitles(of url: URL, size: Int) -> TailTitles {
        let titles = scanTail(of: url, size: size, window: tailWindow)
        guard titles == TailTitles(), size > tailWindow else { return titles }
        return scanTail(of: url, size: size, window: wideTailWindow)
    }

    private static func scanTail(of url: URL, size: Int, window: Int) -> TailTitles {
        guard size > 0, let handle = try? FileHandle(forReadingFrom: url) else { return TailTitles() }
        defer { try? handle.close() }
        let start = max(0, size - window)
        guard (try? handle.seek(toOffset: UInt64(start))) != nil,
              let data = try? handle.read(upToCount: size - start) else { return TailTitles() }
        let bytes = [UInt8](data)

        var titles = TailTitles()
        // Mid-file, the first line is cut off at the front.
        var lineStart = start == 0 ? 0 : (index(of: 0x0A, in: bytes, from: 0).map { $0 + 1 } ?? bytes.count)
        while lineStart < bytes.count {
            let end = index(of: 0x0A, in: bytes, from: lineStart) ?? bytes.count
            let line = bytes[lineStart..<end]
            lineStart = end + 1
            guard contains(customTitleNeedle, in: line) || contains(aiTitleNeedle, in: line),
                  let object = object(from: line) else { continue }
            switch object["type"] as? String {
            case "custom-title":
                if let title = (object["customTitle"] as? String).flatMap(displayTitle) { titles.custom = title }
            case "ai-title":
                if let title = (object["aiTitle"] as? String).flatMap(displayTitle) { titles.ai = title }
            default:
                break
            }
        }
        return titles
    }

    // MARK: - Prompts and titles

    /// Text Claude Code injects as a user turn. Real prompts never start with these.
    static let wrapperPrefixes = [
        "<command-", "<local-command", "<system-reminder", "<bash-", "<task-notification", "<teammate-message",
        "<agent-message", "<cross-session-message", "<user-memory-input", "<user-prompt-submit-hook", "<tick>",
        "Caveat:", "[Request interrupted", "Another Claude session sent a message", "This session is being continued",
    ]

    /// The typed text of a user line, or nil for tool results, meta lines, notifications and command wrappers.
    static func promptText(_ object: [String: Any]) -> String? {
        for flag in ["isMeta", "isSidechain", "isCompactSummary", "isVisibleInTranscriptOnly"] where object[flag] as? Bool == true {
            return nil
        }
        // Newer transcripts say who wrote the turn: task notifications and peer messages are not the user.
        if let origin = object["origin"] as? [String: Any], let kind = origin["kind"] as? String, kind != "human" {
            return nil
        }
        guard let message = object["message"] as? [String: Any] else { return nil }
        let text: String
        if let string = message["content"] as? String {
            text = string
        } else if let parts = message["content"] as? [[String: Any]] {
            guard !parts.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !wrapperPrefixes.contains(where: { trimmed.hasPrefix($0) }) else { return nil }
        return trimmed
    }

    /// First line of the prompt as a title. Image and paste placeholders are dropped, and the user's own words win
    /// over the first line of something they pasted. nil when nothing is left.
    static func title(fromPrompt text: String) -> String? {
        let cleaned = String(text.prefix(32_768))
            .replacingOccurrences(of: #"\[(?:Image|Pasted text) #\d+[^\]\n]*\]"#, with: " ", options: .regularExpression)
        let outsidePastes = cleaned.replacingOccurrences(of: #"<pasted_content[^>]*>[\s\S]*?(?:</pasted_content>|\z)"#,
                                                         with: "\n", options: .regularExpression)
        let withPastes = cleaned.replacingOccurrences(of: #"</?pasted_content[^>]*>"#, with: "\n", options: .regularExpression)
        return displayTitle(outsidePastes) ?? displayTitle(withPastes)
    }

    /// The first non-blank line, whitespace collapsed, capped at `maxTitleLength` with a trailing "…".
    static func displayTitle(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty else { continue }
            let title = words.joined(separator: " ")
            guard title.count > maxTitleLength else { return title }
            return String(title.prefix(maxTitleLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return nil
    }

    // MARK: - Byte helpers

    private static func object(from line: ArraySlice<UInt8>) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
    }

    private static func index(of byte: UInt8, in bytes: [UInt8], from start: Int) -> Int? {
        bytes.withUnsafeBufferPointer { buffer -> Int? in
            guard start < buffer.count, let base = buffer.baseAddress,
                  let hit = memchr(base + start, Int32(byte), buffer.count - start) else { return nil }
            return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
        }
    }

    private static func contains(_ needle: [UInt8], in bytes: ArraySlice<UInt8>) -> Bool {
        bytes.withUnsafeBufferPointer { haystack in
            needle.withUnsafeBufferPointer { pattern in
                guard let base = haystack.baseAddress, let patternBase = pattern.baseAddress else { return false }
                return memmem(base, haystack.count, patternBase, pattern.count) != nil
            }
        }
    }
}
