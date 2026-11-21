import SwiftUI

// Owner: project icons builder (feature/older-section follow-on).

/// A project's icon at 16 pt, or nothing when it has none, so rows without one look as they always did.
struct ProjectIconView: View {
    let root: String
    @ObservedObject private var icons = ProjectIcons.shared

    var body: some View {
        switch icons.icon(forRoot: root) {
        case .image(let image, _):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: 12))
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        case nil:
            EmptyView()
        }
    }
}

/// The "Set Project Icon" submenu for a row's or a section header's context menu.
struct ProjectIconMenu: View {
    let root: String
    let name: String

    var body: some View {
        Menu("Set Project Icon") {
            Button("Choose Image…") { ProjectIconActions.chooseImage(forRoot: root, name: name) }
            Button("Use Emoji…") { ProjectIconActions.chooseEmoji(forRoot: root, name: name) }
            Divider()
            Button("Remove Icon") { ProjectIconActions.remove(forRoot: root) }
                .disabled(ProjectIcons.shared.choice(forRoot: root) == nil)
        }
    }
}
