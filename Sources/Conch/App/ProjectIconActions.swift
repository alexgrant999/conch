import AppKit

// Owner: project icons builder (feature/older-section follow-on).

/// Set Project Icon: choose an image, type an emoji, or remove the custom icon. Called from the sidebar's row and
/// section header menus.
@MainActor
enum ProjectIconActions {
    private static var icons: ProjectIcons { .shared }

    /// An open panel for an image. Conch keeps a downscaled copy, so the original can move or go.
    static func chooseImage(forRoot root: String, name: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ProjectIcons.imageTypes
        panel.prompt = "Use Image"
        panel.message = "Choose an icon for \(name)"
        if !ProjectIcons.isProtected(root) {
            panel.directoryURL = URL(fileURLWithPath: root, isDirectory: true)
        }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                guard await icons.setImage(from: url, forRoot: root) else {
                    AppActions.showError("Could Not Use That Image",
                                         detail: "\(url.lastPathComponent) is not a PNG, JPEG, HEIC, ICO or ICNS image Conch can read.")
                    return
                }
            }
        }
        if let window = AppActions.mainWindow, window.isVisible, !window.isMiniaturized, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// A small field for one emoji.
    static func chooseEmoji(forRoot root: String, name: String) {
        let field = NSTextField(string: icons.choice(forRoot: root)?.emoji ?? "")
        field.placeholderString = "🥁"
        field.font = .systemFont(ofSize: 20)
        field.alignment = .center
        field.usesSingleLineMode = true
        field.frame = NSRect(x: 0, y: 0, width: 64, height: field.intrinsicContentSize.height)

        let alert = NSAlert()
        alert.messageText = "Emoji for \(name)"
        alert.informativeText = "Type or paste one emoji. Press Control-Command-Space for the emoji picker."
        alert.accessoryView = field
        alert.addButton(withTitle: "Use Emoji")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            if !icons.setEmoji(field.stringValue, forRoot: root) {
                AppActions.showError("Not an Emoji", detail: "Type or paste a single emoji, such as 🥁.")
            }
        }
        if let window = AppActions.mainWindow, window.isVisible, !window.isMiniaturized, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    static func remove(forRoot root: String) {
        icons.removeIcon(forRoot: root)
    }
}
