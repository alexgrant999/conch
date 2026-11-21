import Foundation

/// Keeps a file Conch asks Claude to write (the handoff note) out of git, through the repository's
/// `info/exclude`: local to this clone, shared by its linked worktrees, and never committed itself.
enum ContextGitExclude {
    /// Adds `file`, as a path from its work tree root, to the repository's `info/exclude` unless it is listed.
    /// Existing lines are kept. False when the file is not in a git work tree or the exclude file cannot be written.
    @discardableResult
    static func add(_ file: URL) -> Bool {
        let path = file.standardizedFileURL.path
        guard let root = workTreeRoot(above: (path as NSString).deletingLastPathComponent),
              let gitDirectory = commonGitDirectory(root: root) else { return false }
        let pattern = escaped(String(path.dropFirst(root.count).drop { $0 == "/" }))
        let exclude = URL(fileURLWithPath: gitDirectory).appendingPathComponent("info/exclude")

        let existing = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        let listed = existing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if listed.contains(pattern) || listed.contains("/" + pattern) { return true }
        let addition = (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + pattern + "\n"
        do {
            try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: exclude.path) {
                let handle = try FileHandle(forWritingTo: exclude)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(addition.utf8))
            } else {
                try Data(addition.utf8).write(to: exclude)
            }
            return true
        } catch {
            NSLog("Conch: could not add %@ to %@: %@", pattern, exclude.path, error.localizedDescription)
            return false
        }
    }

    /// Nearest folder at or above `directory` that holds a `.git` folder or file.
    private static func workTreeRoot(above directory: String) -> String? {
        var dir = directory
        while true {
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == dir { return nil }
            dir = parent
        }
    }

    /// The `.git` folder itself, or for a linked worktree (a `.git` file saying `gitdir: <path>`) the folder its
    /// `commondir` names, which is where the main repository keeps `info/exclude`.
    private static func commonGitDirectory(root: String) -> String? {
        let dotGit = (root as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }

        guard let link = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = link.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
        let gitDirectory = resolve(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces), against: root)
        let commonFile = (gitDirectory as NSString).appendingPathComponent("commondir")
        guard let common = try? String(contentsOfFile: commonFile, encoding: .utf8) else { return gitDirectory }
        return resolve(common.trimmingCharacters(in: .whitespacesAndNewlines), against: gitDirectory)
    }

    private static func resolve(_ path: String, against base: String) -> String {
        let absolute = path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
        return (absolute as NSString).standardizingPath
    }

    /// gitignore treats `\ * ? [` as pattern syntax anywhere, and `!` or `#` at the start.
    private static func escaped(_ relative: String) -> String {
        var pattern = ""
        for character in relative {
            if "\\*?[".contains(character) { pattern.append("\\") }
            pattern.append(character)
        }
        if pattern.hasPrefix("!") || pattern.hasPrefix("#") { pattern = "\\" + pattern }
        return pattern
    }
}
