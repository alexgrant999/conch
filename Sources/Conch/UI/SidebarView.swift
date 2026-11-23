import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Hosted by the shell agent in an NSHostingController as the split view sidebar.
struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @StateObject private var groupsObserver: SidebarGroupsObserver
    @State private var isDropTargeted = false
    @AppStorage("conch.olderCollapsed") private var isOlderCollapsed = false

    init(store: SessionStore) {
        _store = ObservedObject(wrappedValue: store)
        _groupsObserver = StateObject(wrappedValue: SidebarGroupsObserver(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarTopBar()
            List(selection: selection) {
                ForEach(store.sections) { section in
                    Section {
                        ForEach(section.groups) { group in
                            ForEach(group.sessions) { session in
                                SessionRow(
                                    session: session,
                                    store: store,
                                    isSplitPane: session !== group.sessions.first,
                                    isRenaming: store.renamingSessionID == session.id,
                                    projectRoot: section.id
                                )
                                .tag(session.id)
                            }
                        }
                    } header: {
                        SidebarSectionHeader(section: section)
                    }
                }
                olderSection
            }
            .listStyle(.sidebar)
            // Native double-click (and Return) handling. A tap gesture on the row would fight List selection.
            .contextMenu(forSelectionType: UUID.self) { ids in
                rowMenu(for: ids)
            } primaryAction: { ids in
                if let session = session(for: ids) { AppActions.beginRename(session) }
            }
            ModulesSidebarSection()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: openDroppedFolders)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Groups idle past the setting, below the project sections. Inside the List, so its rows select, navigate and
    /// take the context menu like any other. Hidden when empty.
    @ViewBuilder
    private var olderSection: some View {
        let older = store.olderGroups
        if !older.isEmpty {
            Section(isExpanded: Binding(get: { !isOlderCollapsed }, set: { isOlderCollapsed = !$0 })) {
                ForEach(older) { group in
                    let project = store.project(of: group)
                    ForEach(group.sessions) { session in
                        SessionRow(
                            session: session,
                            store: store,
                            isSplitPane: session !== group.sessions.first,
                            isRenaming: store.renamingSessionID == session.id,
                            projectRoot: project.root,
                            olderProject: project
                        )
                        .tag(session.id)
                    }
                }
            } header: {
                OlderSectionHeader(sessionCount: older.reduce(0) { $0 + $1.sessions.count },
                                   isCollapsed: isOlderCollapsed, settings: store.settings)
            }
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { store.activeSession?.id },
            set: { id in
                guard let id, let session = store.session(withID: id), session !== store.activeSession else { return }
                store.select(session)
            }
        )
    }

    private func session(for ids: Set<UUID>) -> TerminalSession? {
        guard let id = ids.first else { return nil }
        return store.session(withID: id)
    }

    @ViewBuilder
    private func rowMenu(for ids: Set<UUID>) -> some View {
        if let session = session(for: ids) {
            let dir = session.currentDirectory
            Button("Rename") { AppActions.beginRename(session) }
            Divider()
            Button("Split Right with Terminal") {
                store.select(session)
                AppActions.newTerminal(split: true)
            }
            Button("Split Right with Claude") {
                store.select(session)
                AppActions.newClaude(split: true)
            }
            Button("New Claude Session Here") { AppActions.newClaude(in: dir) }
            Button("New Terminal Here") { AppActions.newTerminal(in: dir) }
            Divider()
            Button("Reveal in Finder") { AppActions.revealInFinder(dir) }
            Button("Open in VS Code") { AppActions.openInEditor(dir) }
            Button("Copy Path") { AppActions.copyToPasteboard(dir) }
            if AppActions.claudeSessionID(of: session) != nil {
                Button("Copy Session ID") { AppActions.copySessionID(session) }
            }
            if let group = store.group(containing: session) {
                let project = store.project(of: group)
                Button("Open Project Folder") { AppActions.openProjectFolder(project.root) }
                ProjectIconMenu(root: project.root, name: project.name)
            }
            Divider()
            Button("Close") { AppActions.requestClose(session) }
        }
    }

    private func openDroppedFolders(_ providers: [NSItemProvider]) -> Bool {
        let urlProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        for provider in urlProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL,
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return }
                let path = url.path
                Task { @MainActor in AppActions.newClaude(in: path) }
            }
        }
        return !urlProviders.isEmpty
    }
}

/// Re-renders the sidebar when any group's sessions or focused pane change. Those are published on the
/// group, not the store, and the List selection is derived from the focused pane.
@MainActor
final class SidebarGroupsObserver: ObservableObject {
    private var groupsSubscription: AnyCancellable?
    private var groupSubscriptions: [AnyCancellable] = []

    init(store: SessionStore) {
        groupsSubscription = store.$groups.sink { [weak self] groups in
            self?.observe(groups)
        }
    }

    private func observe(_ groups: [SessionGroup]) {
        groupSubscriptions = groups.map { group in
            group.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
}

private struct SidebarTopBar: View {
    var body: some View {
        HStack(spacing: 6) {
            Button {
                AppActions.newClaude()
            } label: {
                Label("New Claude", systemImage: "sparkle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .help("New Claude Session (⌘N)")

            Button {
                AppActions.newTerminal()
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.bordered)
            .help("New Terminal (⌘T)")

            Button {
                AppActions.showQuickOpen()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .help("Quick Open (⌘P)")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

private struct SidebarSectionHeader: View {
    let section: ProjectSection
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(section.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(section.id.abbreviatingHome)
            Spacer(minLength: 4)
            Button {
                AppActions.openProjectFolder(section.id)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .opacity(isHovering ? 1 : 0)
            .help("Open \(section.name) in Finder (⇧⌘O for the current session's project)")
            Menu {
                Button("New Claude Session") { AppActions.newClaude(in: section.id) }
                Button("New Terminal") { AppActions.newTerminal(in: section.id) }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovering ? 1 : 0)
            .help("New session in \(section.name)")
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open Project Folder") { AppActions.openProjectFolder(section.id) }
            ProjectIconMenu(root: section.id, name: section.name)
        }
    }
}
