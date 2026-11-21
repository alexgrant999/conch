import Foundation

// Owner: worktree builder (feature/worktree).
//
// What Claude Code 2.1.329 does with `--worktree=<name>` (checked against the real CLI, see the feature notes):
// - Creates <main repo root>/.claude/worktrees/<name> on a new branch worktree-<name> and runs inside it, also when
//   started from a subfolder or from inside another worktree of the repo. The transcript is keyed by that folder.
// - Reuses a worktree of that name that already exists, also when started inside it.
// - Recreates a missing folder with `git worktree add -B`, which resets an existing worktree-<name> branch to HEAD.
//   Commits on it then survive only in the reflog, so Conch never passes --worktree in that state.
// - On a normal exit it removes a worktree without changes (folder and branch) and asks about one with changes.
//   SIGHUP (closing the pane, quitting Conch) keeps it.
// - `--resume <id>` re-enters the recorded worktree while the folder exists. Once the folder is gone and
//   unregistered, plain `--resume <id>` says "No conversation found", while `--resume <id> --worktree=<name>` makes a
//   fresh worktree at the same path and finds the transcript again.
// - Refuses --worktree in a folder whose workspace trust was never accepted, prints why and exits (the pane then
//   drops to its shell).

extension LaunchCommand {
    /// Extra claude arguments for a session that runs in a git worktree (`ClaudeOptions.worktree`), see
    /// `worktreeArguments(name:repositoryRoot:resuming:)`. The repository is the one holding `spec.cwd`.
    static func worktreeArguments(for spec: LaunchSpec, resuming: Bool) -> [String] {
        guard spec.kind == .claude, let name = worktreeName(spec.claude) else { return [] }
        guard let root = worktreeRepositoryRoot(for: spec.cwd) else {
            // Outside git there is no branch to lose. A new session lets claude say why it cannot make a worktree.
            return resuming ? [] : ["--worktree=\(name)"]
        }
        return worktreeArguments(name: name, repositoryRoot: root, resuming: resuming)
    }

    /// Always nil: worktree sessions start in the repository root (`spec.cwd`) and claude enters the worktree itself.
    static func worktreeDirectory(for spec: LaunchSpec) -> String? {
        nil
    }

    // MARK: - Helpers shared by the store, menu, palette and badge

    /// - Folder exists: a new session passes `--worktree=<name>` (claude re-enters it), a resumed one passes nothing
    ///   (claude goes back into it from the repository root).
    /// - Folder gone, branch gone (claude removes a clean worktree when it exits normally): `--worktree=<name>`, so
    ///   claude makes a fresh one at the same path, and a resumed conversation comes back.
    /// - Folder gone, branch still there or unreadable: nothing, because --worktree would reset that branch. A new
    ///   session then runs in the repository root, a resumed one either continues there with claude saying the
    ///   worktree no longer exists or reports that it cannot find the conversation. No work is lost.
    static func worktreeArguments(name: String, repositoryRoot root: String, resuming: Bool) -> [String] {
        if worktreeFolder(name: name, repositoryRoot: root) != nil {
            return resuming ? [] : ["--worktree=\(name)"]
        }
        guard worktreeBranchExists(name: name, repositoryRoot: root) == false else { return [] }
        return ["--worktree=\(name)"]
    }

    /// Trimmed worktree name, nil when unset or empty.
    static func worktreeName(_ options: ClaudeOptions?) -> String? {
        let name = options?.worktree?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    /// Where Claude Code puts the worktree of this name, whether or not it exists.
    static func worktreePath(name: String, repositoryRoot root: String) -> String {
        ((root as NSString).appendingPathComponent(".claude/worktrees") as NSString).appendingPathComponent(name)
    }

    /// Branch Claude Code creates for a worktree of this name.
    static func worktreeBranch(name: String) -> String {
        "worktree-\(name)"
    }

    /// The worktree folder when it exists and is a checkout (has a `.git` file), else nil.
    static func worktreeFolder(name: String, repositoryRoot root: String) -> String? {
        let path = worktreePath(name: name, repositoryRoot: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) else { return nil }
        return path
    }

    /// Main repository root for `path`: the nearest folder with a `.git`, except that a linked worktree (a `.git`
    /// file whose gitdir is `<root>/.git/worktrees/<id>` and links back to it) counts as `<root>`. nil outside git.
    /// File reads only, so it is cheap enough for menu validation and sidebar grouping.
    static func worktreeRepositoryRoot(for path: String) -> String? {
        let fileManager = FileManager.default
        var dir = (path.expandingTilde as NSString).standardizingPath
        while true {
            let dotGit = (dir as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return dir }
                return linkedWorktreeMainRoot(gitFile: dotGit, checkout: dir) ?? dir
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == dir { return nil }
            dir = parent
        }
    }

    /// The repository root for a new worktree session from `path`, or nil when Conch should not offer one: outside
    /// git, or a checkout whose refs Conch cannot read (a submodule, a --separate-git-dir checkout, a worktree of a
    /// bare repository, all with a `.git` file, or a reftable repository). Name checks need readable refs.
    static func worktreeCapableRoot(for path: String) -> String? {
        guard let root = worktreeRepositoryRoot(for: path) else { return nil }
        let gitDir = (root as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitDir, isDirectory: &isDirectory), isDirectory.boolValue,
              !FileManager.default.fileExists(atPath: (gitDir as NSString).appendingPathComponent("reftable")) else { return nil }
        return root
    }

    /// Whether the worktree's branch exists, from the loose ref or packed-refs. nil when the repository keeps refs
    /// in a format this does not read (reftable) or its git folder cannot be found.
    static func worktreeBranchExists(name: String, repositoryRoot root: String) -> Bool? {
        let fileManager = FileManager.default
        let gitDir = (root as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitDir, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let ref = "refs/heads/" + worktreeBranch(name: name)
        if fileManager.fileExists(atPath: (gitDir as NSString).appendingPathComponent(ref)) { return true }
        if fileManager.fileExists(atPath: (gitDir as NSString).appendingPathComponent("reftable")) { return nil }
        let packed = (gitDir as NSString).appendingPathComponent("packed-refs")
        guard fileManager.fileExists(atPath: packed) else { return false }
        guard let text = try? String(contentsOfFile: packed, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline).contains { $0.hasSuffix(" " + ref) }
    }

    /// True when a new worktree of this name would collide with a folder or branch already in the repository.
    static func worktreeNameInUse(_ name: String, repositoryRoot root: String) -> Bool {
        FileManager.default.fileExists(atPath: worktreePath(name: name, repositoryRoot: root))
            || worktreeBranchExists(name: name, repositoryRoot: root) != false
    }

    /// `<root>` for a linked worktree, checked the way git does: the `.git` file names `<root>/.git/worktrees/<id>`,
    /// that folder's `gitdir` file points back to this checkout's `.git`, and `<root>/.git` is a directory. Anything
    /// else (a submodule, a crafted or stale `.git` file) gives nil, so the checkout counts as its own root.
    private static func linkedWorktreeMainRoot(gitFile: String, checkout: String) -> String? {
        guard let target = gitdirLine(in: gitFile) else { return nil }
        let adminDir = resolved(target, relativeTo: checkout)
        let marker = "/.git/worktrees/"
        guard let range = adminDir.range(of: marker, options: .backwards) else { return nil }
        let root = String(adminDir[..<range.lowerBound])
        var isDirectory: ObjCBool = false
        guard !root.isEmpty,
              FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git"), isDirectory: &isDirectory),
              isDirectory.boolValue,
              let backlink = gitdirBacklink(adminDir: adminDir),
              let linked = ProcessInspector.physicalPath(backlink),
              let own = ProcessInspector.physicalPath(gitFile), linked == own else { return nil }
        return root
    }

    /// The path after "gitdir:" in a `.git` file.
    private static func gitdirLine(in file: String) -> String? {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let prefix = "gitdir:"
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    /// `<admin dir>/gitdir`: the checkout's `.git` file as git recorded it, absolute or relative to the admin dir.
    private static func gitdirBacklink(adminDir: String) -> String? {
        let file = (adminDir as NSString).appendingPathComponent("gitdir")
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : resolved(path, relativeTo: adminDir)
    }

    private static func resolved(_ path: String, relativeTo base: String) -> String {
        let absolute = path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
        return (absolute as NSString).standardizingPath
    }
}
