import Foundation

// Owner: layouts builder (feature/layouts).

extension SessionStore {
    /// The sidebar section a group sits in: its project root (`id`) and folder name (`name`). A group shown in Older
    /// gets its own project's section, holding just that group.
    func layoutSection(of group: SessionGroup) -> ProjectSection? {
        if let section = sections.first(where: { section in section.groups.contains { $0 === group } }) {
            return section
        }
        guard groups.contains(where: { $0 === group }) else { return nil }
        let project = project(of: group)
        return ProjectSection(id: project.root, name: project.name, groups: [group])
    }

    /// The group's panes, in order, as a layout for its project. nil when the group has nothing a layout keeps
    /// (web sessions are skipped).
    func projectLayout(for group: SessionGroup) -> ProjectLayout? {
        guard let section = layoutSection(of: group) else { return nil }
        let panes = group.sessions.compactMap { session -> LayoutPane? in
            if session.spec.kind == .shell { session.refreshProcessInfo() }
            return LayoutPane.saving(session.spec, customName: session.customName, liveDirectory: session.currentDirectory)
        }
        guard !panes.isEmpty else { return nil }
        return ProjectLayout(id: UUID(), name: section.name, root: section.id, panes: panes)
    }

    /// Opens a layout as one new group: the first pane makes the group and keeps focus, the rest split into it.
    /// Returns the new sessions, empty when no pane has a folder left to start in.
    @discardableResult
    func openLayout(_ layout: ProjectLayout) -> [TerminalSession] {
        var opened: [TerminalSession] = []
        for pane in layout.panes {
            guard let spec = pane.openingSpec(fallbackDirectory: layout.root) else { continue }
            let groupID = opened.first.flatMap { group(containing: $0)?.id }
            opened.append(newSession(spec, customName: pane.customName, splitInto: groupID, select: opened.isEmpty))
        }
        return opened
    }
}

extension LayoutPane {
    /// How a live pane is saved, nil for a web session. Shell panes keep their startup command and their live
    /// folder, except that a pane with a command keeps spec.cwd: the command runs there, and the live folder may be
    /// wherever the command cd'd to. Claude panes get a fresh spec with the same folder and remote control setting,
    /// so no conversation id or worktree is carried into the layout.
    static func saving(_ spec: LaunchSpec, customName: String?, liveDirectory: String) -> LayoutPane? {
        switch spec.kind {
        case .shell:
            let hasCommand = !(spec.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            var saved = LaunchSpec.shell(hasCommand || !layoutIsDirectory(liveDirectory) ? spec.cwd : liveDirectory)
            saved.command = spec.command
            return LayoutPane(customName: customName, spec: saved)
        case .claude:
            return LayoutPane(customName: customName,
                              spec: .claude(spec.cwd, remoteControl: spec.claude?.remoteControl ?? false))
        case .cloud:
            return nil
        }
    }

    /// The spec a session opened from this pane starts with. Claude panes get a new conversation id every time.
    /// A folder that is gone falls back to the layout's root. nil when that is gone too, or for a web session.
    func openingSpec(fallbackDirectory: String) -> LaunchSpec? {
        guard spec.kind != .cloud else { return nil }
        var opening = spec
        if !layoutIsDirectory(opening.cwd) {
            guard layoutIsDirectory(fallbackDirectory) else { return nil }
            opening.cwd = fallbackDirectory
        }
        if opening.kind == .claude {
            var options = opening.claude ?? ClaudeOptions()
            options.sessionID = UUID()
            opening.claude = options
        }
        return opening
    }
}

func layoutIsDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
}
