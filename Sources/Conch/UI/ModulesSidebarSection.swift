import SwiftUI

// Owner: modules builder (feature/modules-section).

/// The collapsible Modules section under the session list. It sits outside the List on purpose, so module rows
/// never take part in session selection, keyboard navigation or the folder drop. Hidden while the modules folder is
/// missing or has no modules.
struct ModulesSidebarSection: View {
    @ObservedObject private var library = ModuleLibrary.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var isHoveringHeader = false

    private static let rowHeight: CGFloat = 34
    private static let maxVisibleRows = 5

    var body: some View {
        if !library.modules.isEmpty {
            VStack(spacing: 0) {
                Divider()
                header
                if !settings.modulesCollapsed {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(library.modules) { module in
                                ModuleSidebarRow(module: module)
                                    .frame(height: Self.rowHeight)
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                    .frame(height: CGFloat(min(library.modules.count, Self.maxVisibleRows)) * Self.rowHeight)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private var header: some View {
        Button {
            settings.modulesCollapsed.toggle()
        } label: {
            HStack(spacing: 4) {
                Text("Modules")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(settings.modulesCollapsed ? 0 : 90))
                    .opacity(isHoveringHeader || settings.modulesCollapsed ? 1 : 0)
            }
            .padding(.horizontal, 18)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringHeader = $0 }
        .help(settings.modulesCollapsed ? "Show modules" : "Hide modules")
        .accessibilityLabel(settings.modulesCollapsed ? "Modules, collapsed" : "Modules, expanded")
    }
}

private struct ModuleSidebarRow: View {
    let module: ModuleInfo
    @State private var isHovering = false

    var body: some View {
        Button {
            ModulesWindowController.shared.present(selecting: module.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(module.name)
                            .lineLimit(1)
                        if let version = module.version {
                            Text(version)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Text(ModulesText.summary(of: module))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .background {
                if isHovering {
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Show \(module.name) in the Modules window")
    }
}

/// Wording shared by the sidebar, the Modules window and the palette.
enum ModulesText {
    /// "9 features · 1 project", plus "· 1 behind" when an install is behind.
    static func summary(of module: ModuleInfo) -> String {
        var parts = [count(module.features.count, "feature"), count(module.installs.count, "project")]
        if module.behindCount > 0 { parts.append("\(module.behindCount) behind") }
        return parts.joined(separator: " · ")
    }

    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}
