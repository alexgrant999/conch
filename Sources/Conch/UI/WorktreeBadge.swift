import SwiftUI

// Owner: worktree builder (feature/worktree). Shown in each sidebar row, before the close button.

struct WorktreeBadge: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if session.spec.kind == .claude, let name = LaunchCommand.worktreeName(session.spec.claude) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .help(tooltip(name: name))
        }
    }

    private func tooltip(name: String) -> String {
        let root = LaunchCommand.worktreeRepositoryRoot(for: session.spec.cwd) ?? session.spec.cwd
        let folder = LaunchCommand.worktreePath(name: name, repositoryRoot: root)
        return "Worktree \(name) on branch \(LaunchCommand.worktreeBranch(name: name))\n\(folder.abbreviatingHome)"
    }
}
