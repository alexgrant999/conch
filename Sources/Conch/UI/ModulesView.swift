import SwiftUI

// Owner: modules builder (feature/modules-section).

/// Content of the Modules window: the module list on the left, the selected module on the right.
struct ModulesView: View {
    @ObservedObject var library: ModuleLibrary
    @ObservedObject var model: ModulesWindowModel

    var body: some View {
        Group {
            if library.modules.isEmpty {
                ModulesEmptyState(library: library)
            } else {
                HStack(spacing: 0) {
                    List(selection: $model.selectedID) {
                        ForEach(library.modules) { module in
                            ModuleListRow(module: module)
                                .tag(module.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(width: 220)

                    Divider()

                    if let module = selectedModule {
                        ModuleDetailView(module: module, activeDirectory: model.activeDirectory)
                            .id(module.id)
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 400)
        .onAppear(perform: keepSelectionValid)
        .onChange(of: library.modules.map(\.id)) { keepSelectionValid() }
    }

    private var selectedModule: ModuleInfo? {
        model.selectedID.flatMap(library.module(withID:))
    }

    /// Falls back to the first module when nothing is selected or the selected one went away.
    private func keepSelectionValid() {
        guard selectedModule == nil, let first = library.modules.first else { return }
        model.selectedID = first.id
    }
}

private struct ModuleListRow: View {
    let module: ModuleInfo

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(module.name)
                    .lineLimit(1)
                Text(ModulesText.summary(of: module))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: "puzzlepiece.extension")
        }
        .padding(.vertical, 2)
    }
}

private struct ModulesEmptyState: View {
    @ObservedObject var library: ModuleLibrary

    var body: some View {
        VStack(spacing: 10) {
            if library.hasLoaded {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text("No Modules")
                    .font(.title3.weight(.semibold))
                Text(detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Settings…") { AppActions.showSettings() }
                    .padding(.top, 4)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detail: String {
        let folder = library.folder.abbreviatingHome
        return layoutIsDirectory(library.folder)
            ? "\(folder) has no module folders with a module.json. Choose another modules folder in Settings."
            : "There is no folder at \(folder). Choose the modules folder in Settings."
    }
}

private struct ModuleDetailView: View {
    let module: ModuleInfo
    let activeDirectory: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                actions

                if !module.features.isEmpty {
                    DetailSection("Features") {
                        ForEach(Array(module.features.enumerated()), id: \.offset) { _, feature in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(.tertiary)
                                Text(feature)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                DetailSection("Installed in") {
                    if module.installs.isEmpty {
                        Text("Not installed in any project yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(module.installs) { install in
                        InstallRow(module: module, install: install)
                    }
                }

                if !module.source.isEmpty {
                    DetailSection("Built from") {
                        ForEach(Array(module.source.enumerated()), id: \.offset) { _, source in
                            Label(source, systemImage: "folder")
                                .labelStyle(SecondaryIconLabelStyle())
                                .help(sourcePath(source).abbreviatingHome)
                        }
                    }
                }

                if !module.seams.isEmpty {
                    DetailSection("Seams") {
                        ForEach(Array(module.seams.enumerated()), id: \.offset) { _, seam in
                            Text(seam)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                if !module.env.isEmpty {
                    DetailSection("Env vars") {
                        // Stacked rather than in columns, so long names never break mid-word in a narrow window.
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(module.env.enumerated()), id: \.offset) { _, variable in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(variable.name)
                                            .font(.system(.body, design: .monospaced))
                                            .textSelection(.enabled)
                                        Text(variable.required ? "required" : "optional")
                                            .font(.system(size: 11))
                                            .foregroundStyle(variable.required ? .primary : .secondary)
                                    }
                                    if !variable.description.isEmpty {
                                        Text(variable.description)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }

                if !module.dependencies.isEmpty {
                    DetailSection("Dependencies") {
                        ForEach(module.dependencies, id: \.self) { dependency in
                            HStack(spacing: 8) {
                                Text(dependency.name)
                                Text(dependency.version)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(module.name)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                if let version = module.version {
                    Text(version)
                        .foregroundStyle(.secondary)
                }
            }
            if let description = module.description {
                Text(description)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Text(module.path.abbreviatingHome)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// One row when the window is wide enough, else the install menu drops to a second row. Never truncated.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                fileButtons
                installMenu
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { fileButtons }
                installMenu
            }
        }
    }

    @ViewBuilder
    private var fileButtons: some View {
        Button {
            ModuleActions.openInClaude(module)
        } label: {
            Label("Open in Claude", systemImage: "sparkle")
        }
        .fixedSize()
        .help("New Claude session in \(module.path.abbreviatingHome)")

        Button("Open README") { ModuleActions.openReadme(module) }
            .fixedSize()
            .disabled(!FileManager.default.fileExists(atPath: module.readmePath))
        Button("Reveal in Finder") { ModuleActions.revealInFinder(module) }
            .fixedSize()
    }

    /// Targets come from the background scan with symlinks resolved, so this only compares strings.
    private var installMenu: some View {
        let targets = ModuleActions.installTargets(for: module, activeDirectory: activeDirectory)
        return Menu("Install in Project…") {
            if let active = targets.active {
                Section("Active session") {
                    Button(active.project.name) { ModuleActions.confirmInstall(module, in: active.project) }
                }
                Section("Other projects") {
                    installButtons(targets.others)
                }
            } else {
                installButtons(targets.others)
            }
        }
        .fixedSize()
        .disabled(targets.active == nil && targets.others.isEmpty)
        .help("Copy this module into a project with install.mjs")
    }

    private func installButtons(_ targets: [InstallTarget]) -> some View {
        ForEach(targets) { target in
            Button(menuTitle(target.project, among: targets)) {
                ModuleActions.confirmInstall(module, in: target.project)
            }
        }
    }

    /// The folder name, plus its parent when another project shares the name.
    private func menuTitle(_ project: ProjectEntry, among list: [InstallTarget]) -> String {
        list.contains { $0.project.name == project.name && $0.project.path != project.path }
            ? "\(project.name) (\(project.detail))" : project.name
    }

    /// Sources are relative to the folder that holds the modules folder (~/development for ~/development/modules).
    private func sourcePath(_ source: String) -> String {
        let base = ((module.path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return ((base as NSString).appendingPathComponent(source) as NSString).standardizingPath
    }
}

private struct InstallRow: View {
    let module: ModuleInfo
    let install: ModuleInstall

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(install.projectName)
                        .fontWeight(.medium)
                    Text(install.version ?? "unknown version")
                        .foregroundStyle(.secondary)
                    if install.isBehind {
                        Text("behind")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.6)))
                            .help("Installed \(install.version ?? "?"), the module is at \(module.version ?? "?")")
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Show Changes") { ModuleActions.showChanges(module, in: install) }
                .disabled(!install.hasBaseline)
                .help(showChangesHelp)
            Button("Update…") { ModuleActions.confirmUpdate(module, in: install) }
        }
        .controlSize(.small)
    }

    private var showChangesHelp: String {
        switch install.commit {
        case ModuleInstall.uncommittedCommit?:
            "Nothing to compare with: \(install.projectName) installed it from uncommitted module code"
        case nil:
            "Nothing to compare with: \(install.projectName)'s modules.json records no commit for it"
        default:
            "What \(install.projectName) changed in the module's files since it installed them"
        }
    }

    private var detail: String {
        let path = install.projectPath.abbreviatingHome
        return install.commit.map { "\(path), commit \($0)" } ?? path
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SecondaryIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(.secondary)
            configuration.title
        }
    }
}
