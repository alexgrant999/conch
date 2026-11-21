import AppKit

// Owner: modules builder (feature/modules-section).

/// Module actions shared by the Modules window, the sidebar section and the palette. Install, update and show
/// changes each run install.mjs in a new terminal in the project, so the output stays on screen.
@MainActor
enum ModuleActions {
    private static var store: SessionStore { SessionStore.shared }

    static func openInClaude(_ module: ModuleInfo) {
        AppActions.newClaude(in: module.path)
    }

    static func openReadme(_ module: ModuleInfo) {
        AppActions.openInEditor(module.readmePath)
    }

    static func revealInFinder(_ module: ModuleInfo) {
        AppActions.revealInFinder(module.path)
    }

    /// The module's install targets, the active session's project first: the deepest target that holds
    /// `activeDirectory` (symlinks already resolved), nil when none does.
    static func installTargets(for module: ModuleInfo, activeDirectory: String?) -> (active: InstallTarget?, others: [InstallTarget]) {
        let candidates = module.installTargets
        guard let here = activeDirectory else { return (nil, candidates) }
        let active = candidates
            .filter { here == $0.resolvedPath || here.hasPrefix($0.resolvedPath + "/") }
            .max { $0.resolvedPath.count < $1.resolvedPath.count }
        return (active, candidates.filter { $0 != active })
    }

    static func confirmInstall(_ module: ModuleInfo, in project: ProjectEntry) {
        guard let command = command(for: module, project: project.path, diff: false) else { return }
        let alert = NSAlert()
        alert.messageText = "Install \(module.name) in \(project.name)?"
        let version = module.version.map { "version \($0)" } ?? "the module version"
        alert.informativeText = "Copies the module's files into \(project.path.abbreviatingHome) and records "
            + "\(version) in its modules.json. Afterwards, wire the seams and add the env vars as the module's "
            + "README describes.\n\nRuns in a new terminal so you can follow the output:\n\(command)"
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            startCommandSession(command, in: project.path, name: "Install \(module.name)")
        }
    }

    /// Runs `--diff`: what the project changed in the module's files since it installed them. Read only, no confirmation.
    static func showChanges(_ module: ModuleInfo, in install: ModuleInstall) {
        guard let command = command(for: module, project: install.projectPath, diff: true) else { return }
        startCommandSession(command, in: install.projectPath, name: "\(module.name) changes")
    }

    static func confirmUpdate(_ module: ModuleInfo, in install: ModuleInstall) {
        guard let command = command(for: module, project: install.projectPath, diff: false) else { return }
        let (alert, choices) = updateAlert(module, in: install, command: command)
        present(alert) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard choices.indices.contains(index) else { return }
            switch choices[index] {
            case .update:
                startCommandSession(command, in: install.projectPath, name: "Update \(module.name)")
            case .showChanges:
                showChanges(module, in: install)
            case .cancel:
                break
            }
        }
    }

    enum UpdateChoice {
        case update, showChanges, cancel
    }

    /// The Update confirmation, with one choice per button in order. What install.mjs does with files the project
    /// changed depends on the commit its modules.json recorded, so the wording follows it. Update is never the
    /// default button: Show Changes is when there is a commit to compare with, else Cancel.
    static func updateAlert(_ module: ModuleInfo, in install: ModuleInstall, command: String) -> (NSAlert, [UpdateChoice]) {
        let project = install.projectName
        let alert = NSAlert()
        alert.messageText = "Update \(module.name) in \(project)?"
        let versions = "Installed \(install.version ?? "unknown version"), module \(module.version ?? "unknown version")."
        let summary: String
        switch install.commit {
        case ModuleInstall.uncommittedCommit?:
            summary = "\(project)'s modules.json records an install from uncommitted module code, so there is nothing "
                + "to merge against and install.mjs treats this as a first install: every file that differs from the "
                + "module is overwritten, and any changes \(project) made to those files are lost. Seam files are not "
                + "touched.\n\n\(versions)"
        case nil:
            summary = "\(project)'s modules.json records no commit for this install, so there is nothing to merge "
                + "against. Files the project does not have are added. Every other file that differs from the module "
                + "is left as it is, with the module's version written beside it as <file>.module to merge by hand. "
                + "Seam files are not touched.\n\n\(versions)"
        default:
            summary = "Check Show Changes first, so nothing \(project) changed in the module's files gets lost in a "
                + "conflict.\n\n\(versions) Files the project never touched are replaced, files it changed are merged, "
                + "and lines both sides changed are left with conflict markers. Seam files are not touched."
        }
        alert.informativeText = summary + "\n\nRuns in a new terminal:\n\(command)"

        guard install.hasBaseline else {
            // Return does nothing here and Escape cancels, so an update that overwrites or copies files always
            // takes a deliberate click. A button holds one key equivalent, so Cancel cannot have both keys.
            let cancel = alert.addButton(withTitle: "Cancel")
            cancel.keyEquivalent = "\u{1b}"
            let update = alert.addButton(withTitle: "Update")
            update.keyEquivalent = ""
            update.hasDestructiveAction = install.commit == ModuleInstall.uncommittedCommit
            return (alert, [.cancel, .update])
        }
        alert.addButton(withTitle: "Show Changes")
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        return (alert, [.showChanges, .update, .cancel])
    }

    /// A terminal in `folder` that runs `command` once, then leaves a shell prompt. The command is cleared from the
    /// spec as soon as the pane starts, so a relaunch restores a plain shell instead of running an install again.
    @discardableResult
    static func startCommandSession(_ command: String, in folder: String, name: String) -> TerminalSession {
        AppActions.showMainWindow()
        var spec = LaunchSpec.shell(folder)
        spec.command = command
        let session = store.newSession(spec, customName: name)
        session.updateSpec { $0.command = nil }
        store.scheduleSave()
        return session
    }

    // MARK: - Helpers

    /// The install (or diff) command, using the modules folder the module was read from. nil, after saying why,
    /// when the project folder or the install script is gone.
    private static func command(for module: ModuleInfo, project: String, diff: Bool) -> String? {
        let folder = (module.path as NSString).deletingLastPathComponent
        let script = ((folder as NSString).appendingPathComponent("bin") as NSString).appendingPathComponent("install.mjs")
        guard layoutIsDirectory(project) else {
            AppActions.showError("Project Not Found", detail: "\(project.abbreviatingHome) no longer exists.")
            return nil
        }
        guard FileManager.default.fileExists(atPath: script) else {
            AppActions.showError("Install Script Not Found", detail: "There is no \(script.abbreviatingHome).")
            return nil
        }
        return diff
            ? ModuleIndex.diffCommand(modulesFolder: folder, module: module.folderName, project: project)
            : ModuleIndex.installCommand(modulesFolder: folder, module: module.folderName, project: project)
    }

    /// As a sheet on the Modules window when it is showing, else on the main window, else app-modal.
    private static func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let candidates = [ModulesWindowController.shared.window, AppActions.mainWindow]
        guard let window = candidates.compactMap({ $0 }).first(where: { $0.isVisible && !$0.isMiniaturized }) else {
            completion(alert.runModal())
            return
        }
        guard window.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }
}
