import AppKit

// Owner: feature/worktree builder.

extension SmokeTest {
    /// Smoke checks for this feature. Record each with `record("<number> <name>", ok, detail)`.
    /// Never runs claude: everything goes through LaunchCommand, the store's name and exclude helpers, and plain shells.
    func checkWorktree(directory: String) async {
        let repo = (directory as NSString).appendingPathComponent("worktree-repo")
        let separate = (directory as NSString).appendingPathComponent("worktree-separate")
        var failures = worktreeRuleFailures(directory: directory, repo: repo)
        if failures.isEmpty {
            failures += worktreeOddCheckoutFailures(directory: directory, separate: separate)
            failures += worktreeExcludeFailures(directory: directory)
            failures += worktreeMenuFailures(repo: repo, separate: separate)
        }
        record("14 worktree", failures.isEmpty, failures.isEmpty ? "all worktree rules hold" : failures.joined(separator: "; "))
    }

    /// Argv, start directory and branch guard rules against a real repository and `git worktree add`.
    private func worktreeRuleFailures(directory: String, repo: String) -> [String] {
        var failures: [String] = []
        if let error = makeRepository(repo) { return [error] }
        try? FileManager.default.createDirectory(atPath: (repo as NSString).appendingPathComponent("sub"),
                                                 withIntermediateDirectories: true)

        let name = "smoke-wt"
        let branch = LaunchCommand.worktreeBranch(name: name)
        let folder = LaunchCommand.worktreePath(name: name, repositoryRoot: repo)
        var spec = LaunchSpec.claude(repo, remoteControl: true)
        spec.claude?.worktree = name
        let id = spec.claude?.sessionID.uuidString.lowercased() ?? ""
        // No transcript exists for this id, so restoring takes the not-resuming path (the no-transcript case).
        func restoredArgv() -> [String] {
            LaunchCommand.claudeArgv(for: spec, displayName: "Smoke", restoring: true) ?? []
        }

        // Repository detection, from the root, a subfolder, and outside git.
        if worktreeCanonical(LaunchCommand.worktreeRepositoryRoot(for: repo)) != worktreeCanonical(repo) {
            failures.append("repository root of the repo: \(LaunchCommand.worktreeRepositoryRoot(for: repo) ?? "nil")")
        }
        if worktreeCanonical(LaunchCommand.worktreeRepositoryRoot(for: repo + "/sub")) != worktreeCanonical(repo) {
            failures.append("repository root of a subfolder: \(LaunchCommand.worktreeRepositoryRoot(for: repo + "/sub") ?? "nil")")
        }
        if worktreeCanonical(LaunchCommand.worktreeCapableRoot(for: repo + "/sub")) != worktreeCanonical(repo) {
            failures.append("a normal repository should allow worktrees")
        }
        if let root = LaunchCommand.worktreeRepositoryRoot(for: directory) {
            failures.append("outside git should have no repository root, got \(root)")
        }

        // New session, no worktree yet: --worktree right after --session-id, starts in the repository.
        let fresh = LaunchCommand.claudeArgv(for: spec, displayName: "Smoke", restoring: false) ?? []
        if Array(fresh.prefix(5)) != ["claude", "--session-id", id, "--worktree=\(name)", "--remote-control=Smoke"] {
            failures.append("new worktree session argv: \(fresh)")
        }
        if !restoredArgv().contains("--worktree=\(name)") || restoredArgv().contains("--resume") {
            failures.append("restore without a transcript should create the worktree: \(restoredArgv())")
        }
        let freshPlan = LaunchCommand.plan(for: spec, sessionID: UUID(), displayName: "Smoke", startDirectory: repo, restoring: false)
        if worktreeCanonical(freshPlan.currentDirectory) != worktreeCanonical(repo) {
            failures.append("new worktree session starts in \(freshPlan.currentDirectory), expected the repository")
        }
        var plain = LaunchSpec.claude(repo, remoteControl: false)
        plain.claude?.worktree = "  "
        if (LaunchCommand.claudeArgv(for: plain, displayName: "Smoke", restoring: false) ?? []).contains(where: { $0.hasPrefix("--worktree") }) {
            failures.append("a blank worktree name still added --worktree")
        }

        // The worktree exists: the pane still starts in the repository (claude enters the worktree itself), a new
        // session re-enters it, a resumed one passes nothing, and the folder maps back to the main repository.
        let added = runGit(["worktree", "add", "-q", "-b", branch, folder], in: repo)
        guard added.ok else { return failures + ["git worktree add failed: \(tail(added.output))"] }
        if worktreeCanonical(LaunchCommand.worktreeFolder(name: name, repositoryRoot: repo)) != worktreeCanonical(folder) {
            failures.append("worktree folder not detected at \(folder)")
        }
        if let dir = LaunchCommand.worktreeDirectory(for: spec) {
            failures.append("worktreeDirectory should always be nil, got \(dir)")
        }
        for restoring in [false, true] {
            let plan = LaunchCommand.plan(for: spec, sessionID: UUID(), displayName: "Smoke", startDirectory: repo, restoring: restoring)
            if worktreeCanonical(plan.currentDirectory) != worktreeCanonical(repo) {
                failures.append("\(restoring ? "restored" : "new") session with the worktree present starts in \(plan.currentDirectory), expected the repository")
            }
        }
        if worktreeCanonical(LaunchCommand.worktreeRepositoryRoot(for: folder)) != worktreeCanonical(repo) {
            failures.append("repository root from inside the worktree: \(LaunchCommand.worktreeRepositoryRoot(for: folder) ?? "nil")")
        }
        if !restoredArgv().contains("--worktree=\(name)") {
            failures.append("restore without a transcript should re-enter the existing worktree: \(restoredArgv())")
        }
        let resumeWithFolder = LaunchCommand.worktreeArguments(name: name, repositoryRoot: repo, resuming: true)
        if !resumeWithFolder.isEmpty { failures.append("resume with the worktree present: \(resumeWithFolder)") }

        // A crafted .git file naming this worktree's real admin folder does not join this repository.
        let crafted = (directory as NSString).appendingPathComponent("worktree-crafted-real")
        if let gitdir = worktreeGitdirLine(of: folder) {
            try? FileManager.default.createDirectory(atPath: crafted, withIntermediateDirectories: true)
            try? "gitdir: \(gitdir)\n".write(toFile: crafted + "/.git", atomically: true, encoding: .utf8)
            if worktreeCanonical(LaunchCommand.worktreeRepositoryRoot(for: crafted)) != worktreeCanonical(crafted) {
                failures.append("a .git file borrowing another worktree's gitdir joined \(LaunchCommand.worktreeRepositoryRoot(for: crafted) ?? "nil")")
            }
        } else {
            failures.append("could not read the worktree's .git file")
        }

        // Folder gone, branch kept: neither a resume nor a restore without a transcript may pass --worktree, since
        // claude would reset the branch.
        let removed = runGit(["worktree", "remove", "--force", folder], in: repo)
        if !removed.ok { failures.append("git worktree remove failed: \(tail(removed.output))") }
        if let dir = LaunchCommand.worktreeFolder(name: name, repositoryRoot: repo) {
            failures.append("worktree folder still detected after git worktree remove: \(dir)")
        }
        if LaunchCommand.worktreeBranchExists(name: name, repositoryRoot: repo) != true {
            failures.append("branch kept after git worktree remove was not found")
        }
        let resumeBranchKept = LaunchCommand.worktreeArguments(name: name, repositoryRoot: repo, resuming: true)
        if !resumeBranchKept.isEmpty {
            failures.append("resume with the folder gone but the branch kept passed \(resumeBranchKept)")
        }
        if restoredArgv().contains(where: { $0.hasPrefix("--worktree") }) {
            failures.append("restore without a transcript, folder gone, branch kept passed --worktree: \(restoredArgv())")
        }

        // Folder and branch gone: recreate, resumed or not.
        _ = runGit(["branch", "-D", branch], in: repo)
        let resumeAllGone = LaunchCommand.worktreeArguments(name: name, repositoryRoot: repo, resuming: true)
        if resumeAllGone != ["--worktree=\(name)"] {
            failures.append("resume with folder and branch gone should recreate the worktree: \(resumeAllGone)")
        }
        if !restoredArgv().contains("--worktree=\(name)") {
            failures.append("restore without a transcript, folder and branch gone, should recreate: \(restoredArgv())")
        }

        // A packed branch counts too.
        _ = runGit(["branch", branch], in: repo)
        _ = runGit(["pack-refs", "--all"], in: repo)
        if LaunchCommand.worktreeBranchExists(name: name, repositoryRoot: repo) != true {
            failures.append("packed branch was not found")
        }

        // New names skip ones already taken by a folder or branch.
        if let date = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 3, minute: 4)) {
            let base = "conch-0102-0304"
            let first = store.uniqueWorktreeName(in: repo, now: date)
            _ = runGit(["branch", LaunchCommand.worktreeBranch(name: base)], in: repo)
            let second = store.uniqueWorktreeName(in: repo, now: date)
            if first != base || second != base + "-2" {
                failures.append("unique names: \(first ?? "nil"), then \(second ?? "nil") after its branch was taken")
            }
        }
        return failures
    }

    /// Checkouts whose refs Conch cannot read, and crafted .git files: no hang, no worktree offered, own section.
    private func worktreeOddCheckoutFailures(directory: String, separate: String) -> [String] {
        var failures: [String] = []

        // --separate-git-dir: a .git file that is not a linked worktree (same shape as a submodule).
        let gitDir = (directory as NSString).appendingPathComponent("worktree-separate-gitdir")
        let initialized = runGit(["init", "-q", "-b", "main", "--separate-git-dir", gitDir, separate], in: directory)
        if !initialized.ok { return ["git init --separate-git-dir failed: \(tail(initialized.output))"] }
        if worktreeCanonical(LaunchCommand.worktreeRepositoryRoot(for: separate)) != worktreeCanonical(separate) {
            failures.append("separate git dir checkout should be its own root, got \(LaunchCommand.worktreeRepositoryRoot(for: separate) ?? "nil")")
        }
        if let root = LaunchCommand.worktreeCapableRoot(for: separate) {
            failures.append("separate git dir checkout should not offer a worktree, got \(root)")
        }
        let started = Date()
        if let name = store.uniqueWorktreeName(in: separate) {
            failures.append("unique name in a checkout with unreadable refs should give up, got \(name)")
        }
        if Date().timeIntervalSince(started) > 2 {
            failures.append("unique name search took \(Date().timeIntervalSince(started)) s")
        }
        var spec = LaunchSpec.claude(separate, remoteControl: false)
        spec.claude?.worktree = "smoke-odd"
        if (LaunchCommand.claudeArgv(for: spec, displayName: "Smoke", restoring: true) ?? []).contains(where: { $0.hasPrefix("--worktree") }) {
            failures.append("a checkout with unreadable refs got --worktree although the branch cannot be checked")
        }

        // Submodule-style .git file inside a superproject.
        let superRepo = (directory as NSString).appendingPathComponent("worktree-super")
        let submodule = (superRepo as NSString).appendingPathComponent("sub")
        if let error = makeRepository(superRepo) { return failures + [error] }
        try? FileManager.default.createDirectory(atPath: superRepo + "/.git/modules/sub", withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: submodule, withIntermediateDirectories: true)
        try? "gitdir: ../.git/modules/sub\n".write(toFile: submodule + "/.git", atomically: true, encoding: .utf8)
        if worktreeCanonical(LaunchCommand.worktreeRepositoryRoot(for: submodule)) != worktreeCanonical(submodule) {
            failures.append("submodule should be its own root, got \(LaunchCommand.worktreeRepositoryRoot(for: submodule) ?? "nil")")
        }
        if LaunchCommand.worktreeCapableRoot(for: submodule) != nil || store.uniqueWorktreeName(in: submodule) != nil {
            failures.append("submodule should not offer a worktree")
        }

        // Crafted .git files: an admin folder that does not exist, and one whose gitdir points at another checkout.
        let missing = (directory as NSString).appendingPathComponent("worktree-crafted-missing")
        try? FileManager.default.createDirectory(atPath: missing, withIntermediateDirectories: true)
        try? "gitdir: \(superRepo)/.git/worktrees/x\n".write(toFile: missing + "/.git", atomically: true, encoding: .utf8)
        let elsewhere = (directory as NSString).appendingPathComponent("worktree-crafted-elsewhere")
        try? FileManager.default.createDirectory(atPath: superRepo + "/.git/worktrees/y", withIntermediateDirectories: true)
        try? "\(directory)/somewhere-else/.git\n".write(toFile: superRepo + "/.git/worktrees/y/gitdir", atomically: true, encoding: .utf8)
        try? FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try? "gitdir: \(superRepo)/.git/worktrees/y\n".write(toFile: elsewhere + "/.git", atomically: true, encoding: .utf8)
        for checkout in [missing, elsewhere] {
            let root = LaunchCommand.worktreeRepositoryRoot(for: checkout)
            if worktreeCanonical(root) != worktreeCanonical(checkout) {
                failures.append("crafted .git in \(checkout.lastPathComponentOrSelf) joined \(root ?? "nil")")
            }
            if LaunchCommand.worktreeCapableRoot(for: checkout) != nil {
                failures.append("crafted .git in \(checkout.lastPathComponentOrSelf) offered a worktree")
            }
        }
        return failures
    }

    /// `.claude/worktrees/` lands in .git/info/exclude once, existing lines stay, and git honours it.
    private func worktreeExcludeFailures(directory: String) -> [String] {
        var failures: [String] = []
        let repo = (directory as NSString).appendingPathComponent("worktree-exclude")
        if let error = makeRepository(repo) { return [error] }
        let info = repo + "/.git/info"
        let exclude = info + "/exclude"
        func patternCount() -> Int {
            let text = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
            return text.split(whereSeparator: \.isNewline).filter { $0 == ".claude/worktrees/" }.count
        }

        try? FileManager.default.createDirectory(atPath: info, withIntermediateDirectories: true)
        try? "# keep me\nnode_modules/".write(toFile: exclude, atomically: true, encoding: .utf8)
        let first = SessionStore.excludeWorktrees(inRepository: repo)
        let second = SessionStore.excludeWorktrees(inRepository: repo)
        let text = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
        if !first || !second || patternCount() != 1 {
            failures.append("exclude after two calls: returned \(first), \(second), pattern listed \(patternCount()) times")
        }
        if !text.hasPrefix("# keep me\nnode_modules/\n") {
            failures.append("existing exclude lines changed: \(text.debugDescription)")
        }

        try? FileManager.default.createDirectory(atPath: repo + "/.claude/worktrees/x", withIntermediateDirectories: true)
        try? "x".write(toFile: repo + "/.claude/worktrees/x/file.txt", atomically: true, encoding: .utf8)
        try? "y".write(toFile: repo + "/.claude/settings.json", atomically: true, encoding: .utf8)
        let status = runGit(["status", "--porcelain", "--untracked-files=all"], in: repo).output
        if status.contains("worktrees") || !status.contains(".claude/settings.json") {
            failures.append("git status with the exclude: \(status.debugDescription)")
        }

        try? FileManager.default.removeItem(atPath: info)
        if !SessionStore.excludeWorktrees(inRepository: repo) || patternCount() != 1 {
            failures.append("exclude was not created when .git/info was missing")
        }
        return failures
    }

    /// The menu item is the only Cmd+Option+N in the app, and it and the palette command follow the active folder.
    private func worktreeMenuFailures(repo: String, separate: String) -> [String] {
        var failures: [String] = []
        func items(in menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        let shortcut = (NSApp.mainMenu.map(items) ?? []).filter {
            $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command, .option]
        }
        guard shortcut.count == 1, let item = shortcut.first, item.title == "New Claude in Worktree",
              item.target === WorktreeMenuTarget.shared else {
            return ["Cmd+Option+N menu items: \(shortcut.map(\.title))"]
        }
        func paletteHasCommand() -> Bool {
            PaletteModel(mode: .commands, store: store, projects: []).items.contains { $0.id == "cmd:New Claude in Worktree" }
        }
        if LaunchCommand.worktreeRepositoryRoot(for: store.defaultDirectory()) == nil {
            if WorktreeMenuTarget.shared.validateMenuItem(item) { failures.append("menu item enabled outside a git repository") }
            if paletteHasCommand() { failures.append("palette offers the command outside a git repository") }
        }
        let inRepo = store.newShell(in: repo)
        if !WorktreeMenuTarget.shared.validateMenuItem(item) { failures.append("menu item disabled with the active session in a repository") }
        if !paletteHasCommand() { failures.append("palette lacks the command with the active session in a repository") }
        store.close(inRepo)
        let inSeparate = store.newShell(in: separate)
        if WorktreeMenuTarget.shared.validateMenuItem(item) { failures.append("menu item enabled in a checkout with a .git file") }
        if paletteHasCommand() { failures.append("palette offers the command in a checkout with a .git file") }
        store.close(inSeparate)
        return failures
    }

    /// `git init` plus an empty commit, nil on success.
    private func makeRepository(_ path: String) -> String? {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            return "could not create \(path): \(error)"
        }
        for args in [["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "init"]] {
            let result = runGit(args, in: path)
            if !result.ok { return "git \(args.joined(separator: " ")) in \(path.lastPathComponentOrSelf) failed: \(tail(result.output))" }
        }
        return nil
    }

    private func worktreeGitdirLine(of checkout: String) -> String? {
        guard let text = try? String(contentsOfFile: checkout + "/.git", encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        return line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
    }

    /// git with no system or global config (a global gpgsign or hooksPath would break the throwaway commits).
    private func runGit(_ args: [String], in dir: String) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Conch Smoke", "-c", "user.email=smoke@conch.invalid", "-C", dir] + args
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "LANG": "C",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (false, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }

    private func worktreeCanonical(_ path: String?) -> String? {
        guard let path else { return nil }
        return ProcessInspector.physicalPath(path) ?? path
    }
}
