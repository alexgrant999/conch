import AppKit
import SwiftUI

/// Kind icons shared by the sidebar rows and the palette.
enum SessionGlyph {
    static let claudeOrange = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)

    static func symbol(for kind: SessionKind) -> String {
        switch kind {
        case .shell: return "terminal"
        case .claude: return "sparkle"
        case .cloud: return "cloud"
        case .codex: return "hexagon"
        }
    }

    static let codexGreen = Color(red: 16 / 255, green: 163 / 255, blue: 127 / 255)

    static func tint(for kind: SessionKind) -> Color {
        switch kind {
        case .claude: return claudeOrange
        case .codex: return codexGreen
        case .shell, .cloud: return .secondary
        }
    }
}

enum SidebarPath {
    /// Last two path components, or the whole path with "~" when it is that short already.
    /// "/Users/a/development/playday/web" gives "playday/web", "/Users/a/development" gives "~/development".
    static func shortDirectory(_ path: String) -> String {
        let abbreviated = path.abbreviatingHome
        let parts = abbreviated.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 2 else { return abbreviated }
        return parts.suffix(2).joined(separator: "/")
    }
}

/// One sidebar row. Observes its own session so status, title and cwd changes only re-render this row.
struct SessionRow: View {
    @ObservedObject var session: TerminalSession
    let store: SessionStore
    let isSplitPane: Bool
    let isRenaming: Bool
    /// The project of the row's section (in Older, the row's own). Its icon, when it has one, leads the row.
    let projectRoot: String
    /// Set for a row in the Older section, whose secondary line names its project.
    let olderProject: (root: String, name: String)?

    @State private var isHovering = false
    @State private var draft = ""
    @State private var escapeMonitor: Any?
    @FocusState private var fieldFocused: Bool

    init(session: TerminalSession, store: SessionStore, isSplitPane: Bool, isRenaming: Bool, projectRoot: String,
         olderProject: (root: String, name: String)? = nil) {
        _session = ObservedObject(wrappedValue: session)
        self.store = store
        self.isSplitPane = isSplitPane
        self.isRenaming = isRenaming
        self.projectRoot = projectRoot
        self.olderProject = olderProject
    }

    var body: some View {
        HStack(spacing: 6) {
            if isSplitPane {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 8)
                    .help("Split pane")
            }
            ProjectIconView(root: projectRoot)
            SessionStatusIcon(kind: session.spec.kind, activity: session.activity, attention: session.attention)
            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    renameField
                } else {
                    nameLine
                }
                Text(secondaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            WorktreeBadge(session: session)
            ContextMeter(session: session)
            if isHovering && !isRenaming {
                Button {
                    AppActions.requestClose(session)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Close (⌘W)")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(session.currentDirectory.abbreviatingHome)
    }

    private var nameLine: some View {
        HStack(spacing: 4) {
            Text(session.displayName)
                .fontWeight(session.attention.rank >= Attention.done.rank ? .semibold : .regular)
                .foregroundStyle(session.activity.isExited ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if session.spec.kind == .claude && session.spec.claude?.remoteControl == true {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("Remote Control: also in claude.ai/code and the Claude app")
            }
        }
    }

    private var renameField: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .focused($fieldFocused)
            .onSubmit { commitRename(refocusTerminal: true) }
            .onAppear {
                draft = session.displayName
                // SwiftUI's onExitCommand does not reliably see Escape inside a TextField's field editor.
                escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == 53, store.renamingSessionID == session.id,
                          let window = event.window, window === AppActions.mainWindow,
                          (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return event }
                    cancelRename()
                    return nil
                }
                // Focus has to wait until the field is in the window, or the request is dropped.
                DispatchQueue.main.async { fieldFocused = true }
            }
            .onDisappear {
                if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
                escapeMonitor = nil
            }
            .onChange(of: fieldFocused) { _, focused in
                // Clicking elsewhere commits, like Finder.
                if !focused { commitRename(refocusTerminal: false) }
            }
    }

    private var secondaryText: String {
        let status: String?
        if case .exited(let code) = session.activity {
            if let code, code != 0 { status = "exited (\(code))" } else { status = "exited" }
        } else {
            status = session.foregroundProcess
        }
        guard let olderProject else { return status ?? SidebarPath.shortDirectory(session.currentDirectory) }
        return SidebarPath.olderDetail(project: olderProject.name, root: olderProject.root,
                                       directory: session.currentDirectory, status: status)
    }

    private func commitRename(refocusTerminal: Bool) {
        guard store.renamingSessionID == session.id else { return }
        store.renamingSessionID = nil
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Leaving the program's title untouched must not pin it as a custom name.
        let unchanged = session.customName == nil ? name == session.displayName : name == session.customName
        if !unchanged {
            store.rename(session, to: name.isEmpty ? nil : name)
        }
        if refocusTerminal { store.activeSession?.focus() }
    }

    private func cancelRename() {
        guard store.renamingSessionID == session.id else { return }
        store.renamingSessionID = nil
        store.activeSession?.focus()
    }
}

struct SessionStatusIcon: View {
    let kind: SessionKind
    let activity: ActivityState
    let attention: Attention

    var body: some View {
        icon.frame(width: 16, height: 16)
    }

    @ViewBuilder
    private var icon: some View {
        if activity.isExited {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(Color.gray.opacity(0.6))
                .help("Exited")
        } else if activity == .busy {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .help("Working")
        } else {
            switch attention {
            case .needsInput(let message):
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .help(message ?? "Waiting for your input")
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.green)
                    .help("Finished")
            case .unread:
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .help("New output")
            case .none:
                Image(systemName: SessionGlyph.symbol(for: kind))
                    .font(.system(size: 12))
                    .foregroundStyle(SessionGlyph.tint(for: kind))
            }
        }
    }
}
