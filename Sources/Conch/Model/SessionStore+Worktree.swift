import Foundation

// Owner: worktree builder (feature/worktree).

extension SessionStore {
    private static let worktreeNameAttempts = 100
    private static let worktreeExcludePattern = ".claude/worktrees/"

    /// Repository root for a new worktree session from `dir`, or from the active session's folder (else the default
    /// folder) when nil. nil when Conch does not offer one there, see `LaunchCommand.worktreeCapableRoot(for:)`.
    func worktreeCapableRoot(_ dir: String? = nil) -> String? {
        LaunchCommand.worktreeCapableRoot(for: dir ?? defaultDirectory())
    }

    /// Claude session in a new git worktree of the repository that holds `dir` (or the active folder). It runs from
    /// the repository root with `--worktree=<name>`, so it stays in the repository's sidebar section, and Claude Code
    /// creates `.claude/worktrees/<name>` on branch `worktree-<name>`. nil when no worktree can be offered there or no
    /// free name was found.
    @discardableResult
    func newClaudeInWorktree(in dir: String? = nil) -> TerminalSession? {
        guard let root = LaunchCommand.worktreeCapableRoot(for: resolvedDirectory(dir)),
              let name = uniqueWorktreeName(in: root) else { return nil }
        Self.excludeWorktrees(inRepository: root)
        var spec = LaunchSpec.claude(root, remoteControl: settings.remoteControlByDefault)
        spec.claude?.worktree = name
        return newSession(spec)
    }

    /// "conch-1120-1452" (local month, day, hour, minute), with "-2", "-3" and so on when that name is already used by a
    /// session here or by a folder or branch in the repository. nil after 100 taken names.
    func uniqueWorktreeName(in root: String, now: Date = Date()) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMdd-HHmm"
        let base = "conch-" + formatter.string(from: now)
        let taken = Set(allSessions.compactMap { LaunchCommand.worktreeName($0.spec.claude) })
        for attempt in 1...Self.worktreeNameAttempts {
            let candidate = attempt == 1 ? base : "\(base)-\(attempt)"
            if !taken.contains(candidate), !LaunchCommand.worktreeNameInUse(candidate, repositoryRoot: root) {
                return candidate
            }
        }
        return nil
    }

    /// Lists `.claude/worktrees/` in `<root>/.git/info/exclude` unless it is there already, so worktree folders never
    /// show as untracked or get swept into `git add -A`. Keeps every existing line. Returns true when the pattern is
    /// listed afterwards.
    @discardableResult
    static func excludeWorktrees(inRepository root: String) -> Bool {
        let info = ((root as NSString).appendingPathComponent(".git") as NSString).appendingPathComponent("info")
        let exclude = (info as NSString).appendingPathComponent("exclude")
        var text = ""
        if FileManager.default.fileExists(atPath: exclude) {
            // A file that is not UTF-8 is left alone rather than rewritten.
            guard let existing = try? String(contentsOfFile: exclude, encoding: .utf8) else { return false }
            text = existing
        }
        let listed = Set([worktreeExcludePattern, "/" + worktreeExcludePattern, ".claude/worktrees", "/.claude/worktrees"])
        if text.split(whereSeparator: \.isNewline).contains(where: { listed.contains($0.trimmingCharacters(in: .whitespaces)) }) {
            return true
        }
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += "# Claude Code worktrees, added by Conch\n" + worktreeExcludePattern + "\n"
        do {
            try FileManager.default.createDirectory(atPath: info, withIntermediateDirectories: true)
            try text.write(toFile: exclude, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
