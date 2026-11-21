import Foundation

// Owner: feature/layouts builder.

extension SmokeTest {
    /// Smoke checks for this feature. Record each with `record("<number> <name>", ok, detail)`.
    /// 13 covers saving, listing and opening a layout. 13b covers startup commands: one that cds into a subfolder and
    /// ends in a comment must drop into a shell, and must still work after a restore, which starts the shell where
    /// it was last left (the subfolder) unless the command pins spec.cwd.
    func checkLayouts(directory: String) async {
        // interactivecomments on its own line, so "#" starts a comment under zsh whatever the user's rc sets (zsh
        // parses a whole line before running it). bash has it on already and ignores the failed setopt.
        let command = "setopt interactivecomments 2>/dev/null\ncd layout-pane && echo CONCH_STARTUP_$((6*7)) # in layout-pane"
        let logsCommand = "echo CONCH_LOGS_$((6*7))"
        let paneDirectory = (directory as NSString).appendingPathComponent("layout-pane")
        try? FileManager.default.createDirectory(atPath: paneDirectory, withIntermediateDirectories: true)
        var failures = layoutPaneRuleFailures(directory: directory, subfolder: paneDirectory)
        var startupFailures = startupPlanFailures(directory: directory)
        var created: [TerminalSession] = []
        defer { created.forEach(store.close) }
        func bail(_ reason: String) {
            record("13 layouts", false, (failures + [reason]).joined(separator: "; "))
            record("13b startup commands", false, (startupFailures + ["not reached: \(reason)"]).joined(separator: "; "))
        }

        // A shell with that startup command, plus a plain shell split next to it that then moves to the subfolder.
        var startupSpec = LaunchSpec.shell(directory)
        startupSpec.command = command
        let startup = store.newSession(startupSpec)
        let plain = store.newSession(.shell(directory), customName: "logs", splitInto: store.group(containing: startup)?.id)
        created += [startup, plain]
        let ran = await waitUntil(8) { startup.bufferText().contains("CONCH_STARTUP_42") }
        if !ran { startupFailures.append("startup command did not run, buffer tail: \(tail(startup.bufferText()))") }

        // The trailing comment must not swallow the exec: the pane gets a prompt and runs what is typed next.
        _ = await waitUntil(4) {
            !(startup.bufferText().components(separatedBy: "CONCH_STARTUP_42").last ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        await pause(0.3)
        startup.send(text: "echo CONCH_AFTER_$((6*7))\r")
        let stillShell = await waitUntil(4) { startup.bufferText().contains("CONCH_AFTER_42") }
        if !stillShell || startup.activity.isExited {
            startupFailures.append("no shell after a command ending in a comment, activity \(startup.activity)")
        }
        startup.refreshProcessInfo()
        if layoutCanonical(startup.currentDirectory) != layoutCanonical(paneDirectory) {
            startupFailures.append("the command's cd did not move the shell, at \(startup.currentDirectory)")
        }

        _ = await waitUntil(4) { !plain.bufferText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        await pause(0.3)
        plain.send(text: "cd layout-pane\r")
        let moved = await waitUntil(3) {
            plain.refreshProcessInfo()
            return layoutCanonical(plain.currentDirectory) == layoutCanonical(paneDirectory)
        }
        if !moved { failures.append("plain shell did not reach layout-pane, at \(plain.currentDirectory)") }

        // Set Startup Command pins a new command to the live folder, and keeps the folder of an existing command
        // even though that command moved the shell.
        LayoutActions.applyStartupCommand(logsCommand, to: plain)
        if plain.spec.command != logsCommand || layoutCanonical(plain.spec.cwd) != layoutCanonical(paneDirectory) {
            startupFailures.append("new command stored as \(plain.spec), expected its live folder")
        }
        LayoutActions.applyStartupCommand(command, to: startup)
        if startup.spec.command != command || startup.spec.cwd != directory {
            startupFailures.append("editing a command moved it to \(startup.spec.cwd)")
        }

        guard let group = store.selectedGroup, group.sessions.map(\.id) == [startup.id, plain.id],
              let layout = store.projectLayout(for: group) else {
            bail("no layout for the selected group")
            return
        }
        let panes = layout.panes
        if layout.root != directory || layout.name != directory.lastPathComponentOrSelf {
            failures.append("layout root \(layout.root) name \(layout.name)")
        }
        // The command pane is saved with spec.cwd, not the subfolder its own cd left the shell in.
        if panes.count != 2 || panes.first?.spec != startup.spec {
            failures.append("saved panes \(panes.map(\.spec)), expected first \(startup.spec)")
        }
        if panes.count == 2, panes[1].spec != plain.spec || panes[1].customName != "logs" {
            failures.append("second pane saved as \(panes[1])")
        }

        let layouts = LayoutStore.shared
        layouts.save(layout)
        defer { layouts.delete(id: layout.id) }
        let reloaded = LayoutStore.read(from: layouts.fileURL)
        if reloaded.filter({ $0 == layout }).count != 1 {
            failures.append("layouts.json round trip lost the layout (\(reloaded.count) layouts read back)")
        }

        // The palette offers both commands for this shell group, and Quick Open lists the layout. Its Return action
        // is what opens the layout below.
        let palette = PaletteModel(mode: .commands, store: store, projects: [])
        let commands = Set(palette.items.map(\.title))
        if !commands.isSuperset(of: ["Set Startup Command…", "Save Layout for This Project"]) {
            failures.append("command palette lacks the layout commands")
        }
        palette.setMode(.quickOpen)
        palette.query = LayoutActions.title(of: layout)
        guard let row = palette.items.first(where: { $0.id == "layout:\(layout.id.uuidString)" }),
              row.detail == LayoutActions.summary(of: panes), row.hint == "↩ Open  ⌘↩ Delete" else {
            bail("no Quick Open row for the layout in \(palette.items.map(\.title))")
            return
        }

        let groupIDs = Set(store.groups.map(\.id))
        row.primary()
        let newGroup = store.groups.first { !groupIDs.contains($0.id) }
        let opened = newGroup?.sessions ?? []
        created += opened
        let specs = opened.map(\.spec)
        if store.selectedGroupID != newGroup?.id || specs != panes.map(\.spec)
            || opened.map(\.customName) != panes.map(\.customName) {
            failures.append("opened group \(specs), expected \(panes.map(\.spec))")
        }
        if newGroup?.focusedSessionID != opened.first?.id {
            failures.append("opened group focuses \(String(describing: newGroup?.focusedSessionID)), not its first pane")
        }
        if opened.count == 2 {
            let ranAgain = await waitUntil(8) {
                opened[0].bufferText().contains("CONCH_STARTUP_42") && opened[1].bufferText().contains("CONCH_LOGS_42")
            }
            if !ranAgain { failures.append("startup commands did not run in the opened layout") }
        }

        record("13 layouts", failures.isEmpty,
               failures.isEmpty ? "layout of 2 panes saved (the cd pane at its own folder), read back, listed in Quick "
                                    + "Open and opened from it as a new group that ran both startup commands"
                                : failures.joined(separator: "; "))

        // Restore the original group the way a relaunch does. The save records the subfolder as the startup pane's
        // last folder, which is where a restored shell would start if the command did not pin spec.cwd.
        store.save()
        let savedStartup = Persistence.load()?.groups.first { $0.id == group.id }?.sessions.first { $0.id == startup.id }
        if layoutCanonical(savedStartup?.lastDirectory ?? "") != layoutCanonical(paneDirectory) {
            startupFailures.append("saved lastDirectory \(savedStartup?.lastDirectory ?? "nil"), expected layout-pane")
        }
        created.removeAll { $0 === startup || $0 === plain }
        store.close(startup)
        store.close(plain)
        store.restore()
        let restored = [startup.id, plain.id].compactMap(store.session(withID:))
        created += restored
        if restored.count == 2 {
            let ranAfterRestore = await waitUntil(8) {
                restored[0].bufferText().contains("CONCH_STARTUP_42") && restored[1].bufferText().contains("CONCH_LOGS_42")
            }
            if !ranAfterRestore {
                startupFailures.append("startup commands did not run after a restore, buffer tails: "
                    + "\(tail(restored[0].bufferText())) | \(tail(restored[1].bufferText()))")
            }
        } else {
            startupFailures.append("restore brought back \(restored.count) of 2 panes")
        }

        record("13b startup commands", startupFailures.isEmpty,
               startupFailures.isEmpty ? "a command that cds into a subfolder and ends in a comment ran, left a working "
                                           + "shell and ran again after a restore; new commands pin the live folder"
                                       : startupFailures.joined(separator: "; "))
    }

    /// A shell with a startup command starts in spec.cwd whatever the start directory, joined to the exec by a
    /// newline. A bare shell still starts in the start directory.
    private func startupPlanFailures(directory: String) -> [String] {
        var failures: [String] = []
        var spec = LaunchSpec.shell(directory)
        spec.command = "npm run dev # dev server"
        let elsewhere = NSHomeDirectory()
        let shell = LaunchCommand.shellQuote(LaunchCommand.userShell())
        let plan = LaunchCommand.plan(for: spec, sessionID: UUID(), displayName: "Smoke", startDirectory: elsewhere, restoring: true)
        if plan.currentDirectory != directory {
            failures.append("command shell starts in \(plan.currentDirectory), expected spec.cwd")
        }
        if plan.args != ["-l", "-i", "-c", "npm run dev # dev server\nexec \(shell) -l"] {
            failures.append("command shell args \(plan.args)")
        }
        let bare = LaunchCommand.plan(for: .shell(directory), sessionID: UUID(), displayName: "Smoke",
                                      startDirectory: elsewhere, restoring: true)
        if bare.currentDirectory != elsewhere || bare.args != ["-l"] {
            failures.append("bare shell plan \(bare.currentDirectory) \(bare.args)")
        }
        return failures
    }

    /// Which folder shell panes save with, what Claude and web panes save as, the fresh conversation id on every
    /// open, and the folder fallback.
    private func layoutPaneRuleFailures(directory: String, subfolder: String) -> [String] {
        var failures: [String] = []
        var withCommand = LaunchSpec.shell(directory)
        withCommand.command = "npm run dev"
        if LayoutPane.saving(withCommand, customName: nil, liveDirectory: subfolder)?.spec.cwd != directory {
            failures.append("a pane with a startup command was saved with its live folder")
        }
        if LayoutPane.saving(.shell(directory), customName: nil, liveDirectory: subfolder)?.spec.cwd != subfolder {
            failures.append("a plain shell pane was not saved with its live folder")
        }
        var claude = LaunchSpec.claude(directory, remoteControl: true)
        claude.claude?.worktree = "feature-x"
        claude.claude?.initialPrompt = "hello"
        let liveID = claude.claude?.sessionID

        if let saved = LayoutPane.saving(claude, customName: "Planner", liveDirectory: NSHomeDirectory()) {
            let options = saved.spec.claude
            if saved.spec.kind != .claude || saved.spec.cwd != directory || saved.customName != "Planner"
                || options?.remoteControl != true || options?.worktree != nil || options?.initialPrompt != nil
                || options?.sessionID == liveID {
                failures.append("claude pane saved as \(saved)")
            }
            let first = saved.openingSpec(fallbackDirectory: directory)?.claude?.sessionID
            let second = saved.openingSpec(fallbackDirectory: directory)?.claude?.sessionID
            if first == nil || first == options?.sessionID || first == second {
                failures.append("opening a claude pane does not give a fresh session id")
            }
        } else {
            failures.append("claude pane not saved")
        }

        if LayoutPane.saving(.cloud(directory, target: "fix the login bug"), customName: nil, liveDirectory: directory) != nil {
            failures.append("web pane saved")
        }

        let missing = LayoutPane(customName: nil, spec: .shell((directory as NSString).appendingPathComponent("gone")))
        if missing.openingSpec(fallbackDirectory: directory)?.cwd != directory {
            failures.append("missing folder does not fall back to the layout root")
        }
        if missing.openingSpec(fallbackDirectory: (directory as NSString).appendingPathComponent("gone")) != nil {
            failures.append("missing folder and root still opens")
        }
        return failures
    }
}

/// realpath, so /var and /private/var compare equal.
private func layoutCanonical(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
