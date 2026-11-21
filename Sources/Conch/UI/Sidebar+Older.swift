import SwiftUI

// Owner: older builder (feature/older-section).

/// Header of the Older section at the bottom of the session list. The same quiet header as a project's, plus how many
/// sessions it holds while folded away. Folding is the sidebar list's own disclosure arrow.
struct OlderSectionHeader: View {
    let sessionCount: Int
    let isCollapsed: Bool
    @ObservedObject var settings: AppSettings

    var body: some View {
        // The count sits by the title, clear of the trailing edge where the list draws its arrow on hover.
        HStack(spacing: 6) {
            Text("Older")
                .lineLimit(1)
            if isCollapsed {
                Text("\(sessionCount)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .help("No typing, output or viewing for \(OlderText.duration(hours: settings.olderAfterHours)). Type into "
            + "one, or select it, to move it back to its project.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isCollapsed ? "Older, \(OlderText.sessions(sessionCount)), collapsed" : "Older")
    }
}

/// Wording shared by the sidebar and Settings.
enum OlderText {
    /// "1 hour", "6 hours".
    static func duration(hours: Int) -> String {
        hours == 1 ? "1 hour" : "\(hours) hours"
    }

    /// The Settings choice: "Off", else the duration.
    static func choice(hours: Int) -> String {
        hours == 0 ? "Off" : duration(hours: hours)
    }

    static func sessions(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }
}

extension SidebarPath {
    /// Secondary line of a row in Older. It leads with the project's name, so rows from different projects stay
    /// readable side by side: "playday · node" or "playday · exited" with a status, "playday" at the project root,
    /// "playday/web" below it, and "playday · ~/elsewhere" (the usual short form) anywhere else.
    static func olderDetail(project: String, root: String, directory: String, status: String?) -> String {
        if let status { return "\(project) · \(status)" }
        if directory == root { return project }
        if directory.hasPrefix(root + "/") { return project + "/" + directory.dropFirst(root.count + 1) }
        return "\(project) · \(shortDirectory(directory))"
    }
}
