import AppKit
import SwiftUI

// Owner: shell agent.

/// Settings window. Every control writes straight to AppSettings, so changes apply live.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let store = SessionStore.shared
        let hosting = NSHostingController(rootView: SettingsView(settings: store.settings, store: store))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 520, height: 620))
        window.contentMinSize = NSSize(width: 440, height: 360)
        window.center()
        window.setFrameUsingName("ConchSettingsWindow")
        window.setFrameAutosaveName("ConchSettingsWindow")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        AppActions.activateApp()
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let store: SessionStore

    var body: some View {
        Form {
            Section("Terminal") {
                Stepper(value: $settings.fontSize, in: 9...32, step: 1) {
                    LabeledContent("Font size", value: "\(Int(settings.fontSize)) pt")
                }
                Toggle(isOn: $settings.optionAsMeta) {
                    Text("Use Option as Meta")
                    Text("Needed for Option+Return newlines and word motions in Claude Code.")
                }
            }

            Section("Claude") {
                Toggle(isOn: $settings.remoteControlByDefault) {
                    Text("Remote Control for new Claude sessions")
                    Text("New sessions also appear in claude.ai/code and the Claude app, so you can follow them from anywhere.")
                }
                Toggle(isOn: $settings.showUsageInToolbar) {
                    Text("Show usage in toolbar")
                    Text("Your plan's 5-hour and weekly limits and the last prompt's cost, as Claude Code reports them. Click it for cost by main model.")
                }
            }

            Section("Sessions") {
                Toggle("Restore sessions on launch", isOn: $settings.restoreSessionsOnLaunch)
                Toggle("Notify when a session finishes", isOn: $settings.notifyWhenDone)
                Toggle("Notify on bell or when a session needs input", isOn: $settings.notifyOnBell)
                Toggle(isOn: $settings.showInMenuBar) {
                    Text("Show in menu bar")
                    Text("Shows how many sessions are waiting for you. Press ⌘J to jump to the next one.")
                }
                Picker(selection: $settings.olderAfterHours) {
                    ForEach(AppSettings.olderAfterChoices, id: \.self) { hours in
                        Text(OlderText.choice(hours: hours)).tag(hours)
                    }
                } label: {
                    Text("Move idle sessions to Older after")
                    Text("Sessions with no typing, output or viewing for this long move to the Older section at the bottom of the sidebar.")
                }
            }

            Section {
                LabeledContent("Default directory") {
                    HStack {
                        TextField("Default directory", text: $settings.defaultDirectory)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseDefaultDirectory() }
                    }
                }
            } footer: {
                Text("New sessions start here when no session is active.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(settings.projectRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(root)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            settings.projectRoots.removeAll { $0 == root }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(root)")
                    }
                }
                Button("Add Folder…") { addProjectRoot() }
            } header: {
                Text("Project folders")
            } footer: {
                Text("Quick Open lists the projects it finds in these folders.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundStyle(.secondary)
                    Text(settings.modulesFolder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseModulesFolder() }
                }
            } header: {
                Text("Modules folder")
            } footer: {
                Text("The sidebar's Modules section lists the modules in this folder and the projects that installed them. It stays hidden while the folder has none.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 360)
        .onChange(of: settings.fontSize) { store.applyAppearanceToAll() }
        .onChange(of: settings.optionAsMeta) { store.applyAppearanceToAll() }
    }

    private func addProjectRoot() {
        chooseFolder(prompt: "Add", startingAt: "~/development") { path in
            let stored = path.abbreviatingHome
            if !settings.projectRoots.contains(stored) {
                settings.projectRoots.append(stored)
            }
        }
    }

    private func chooseDefaultDirectory() {
        chooseFolder(prompt: "Choose", startingAt: settings.defaultDirectory) { path in
            settings.defaultDirectory = path.abbreviatingHome
        }
    }

    private func chooseModulesFolder() {
        chooseFolder(prompt: "Choose", startingAt: settings.modulesFolder) { path in
            settings.modulesFolder = path.abbreviatingHome
        }
    }

    private func chooseFolder(prompt: String, startingAt start: String, then use: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.directoryURL = URL(fileURLWithPath: start.expandingTilde, isDirectory: true)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            use(url.path)
        }
        if let window = SettingsWindowController.shared.window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}
