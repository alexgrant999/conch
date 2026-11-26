import SwiftUI

// Owner: model builder (feature/model). Shown in the main window's toolbar, before the usage strip.

/// The session the picker shows. MainWindowController sets it to the active session.
@MainActor
final class ModelPickerState: ObservableObject {
    @Published var session: TerminalSession?
}

/// The active Claude session's model, as a menu of the model families. Nothing for other sessions.
struct ModelPicker: View {
    @ObservedObject var state: ModelPickerState

    var body: some View {
        if let session = state.session, session.spec.kind == .claude {
            ModelMenu(session: session)
        } else {
            // A toolbar item whose view measures zero wide logs a warning on every layout pass.
            Color.clear.frame(width: 1, height: 22)
        }
    }
}

private struct ModelMenu: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        Menu {
            ForEach(ClaudeModels.families) { family in
                Menu(family.name) {
                    entry(family.latest)
                    Divider()
                    ForEach(family.versions) { entry($0) }
                }
            }
            Divider()
            Button("Other Model…") { ModelActions.chooseOther(for: session) }
        } label: {
            Text(ModelActions.label(for: session))
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 4)
        .help("Model for this session. Pick another to switch it when Claude is at its prompt.")
        .accessibilityLabel("Model: \(ModelActions.label(for: session))")
    }

    /// A checkmark item: on for the session's model, choosing switches to it.
    private func entry(_ choice: ClaudeModelChoice) -> some View {
        Toggle(choice.name, isOn: Binding(
            get: { ModelActions.isCurrent(choice, for: session) },
            set: { _ in ModelActions.choose(choice, for: session) }
        ))
    }
}
