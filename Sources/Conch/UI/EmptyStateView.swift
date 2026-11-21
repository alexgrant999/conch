import SwiftUI

/// Shown in the content area by the shell agent's container when there are no sessions.
struct EmptyStateView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text(ConchInfo.appName)
                    .font(.system(size: 28, weight: .semibold))
                Text("Run Claude Code and terminals side by side")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                Button {
                    AppActions.newClaude()
                } label: {
                    actionLabel("New Claude Session", symbol: "sparkle", shortcut: "⌘N")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    AppActions.newTerminal()
                } label: {
                    actionLabel("New Terminal", symbol: "terminal", shortcut: "⌘T")
                }
                .buttonStyle(.bordered)

                Button {
                    AppActions.showQuickOpen()
                } label: {
                    actionLabel("Quick Open", symbol: "magnifyingglass", shortcut: "⌘P")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .frame(width: 280)

            RecentDirectoryLinks(settings: store.settings)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func actionLabel(_ title: String, symbol: String, shortcut: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(shortcut).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RecentDirectoryLinks: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        let recents = settings.recentDirectories.filter(isDirectory).prefix(5)
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(Array(recents), id: \.self) { path in
                    Button {
                        AppActions.newClaude(in: path)
                    } label: {
                        Label(path.abbreviatingHome, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help("New Claude session in \(path.abbreviatingHome)")
                }
            }
            .frame(width: 280, alignment: .leading)
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
