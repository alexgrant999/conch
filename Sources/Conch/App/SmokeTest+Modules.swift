import AppKit

// Owner: modules builder (feature/modules-section).

extension SmokeTest {
    /// Smoke check 16. Builds a throwaway modules folder and projects folder under `directory` and points the
    /// settings at them, so it never reads ~/development. Never runs install.mjs: the quoting check runs the command
    /// against a stub `node` that prints its arguments.
    func checkModules(directory: String) async {
        let modulesFolder = (directory as NSString).appendingPathComponent("mod's folder")
        let projectsRoot = (directory as NSString).appendingPathComponent("module projects")
        let fixture = ModuleFixture(modulesFolder: modulesFolder, projectsRoot: projectsRoot)
        if let error = fixture.write() {
            record("16 modules", false, "fixture: \(error)")
            return
        }

        let snapshot = await Task.detached {
            ModuleIndex.load(modulesFolder: modulesFolder, projectRoots: [projectsRoot])
        }.value
        var failures = moduleParseFailures(snapshot)
        failures += moduleTargetFailures(snapshot, fixture: fixture)
        failures += moduleUpdateAlertFailures()
        failures += moduleVersionFailures()
        failures += await moduleCommandFailures(fixture: fixture, directory: directory)
        failures += await moduleLibraryFailures(fixture: fixture, directory: directory)
        failures += await moduleSessionFailures(directory: directory)
        failures += moduleMenuFailures()
        record("16 modules", failures.isEmpty, failures.isEmpty ? "all module rules hold" : failures.joined(separator: "; "))
    }

    /// Manifest parsing, the README fallback, skipped folders, install detection and the behind flag.
    private func moduleParseFailures(_ snapshot: ModuleSnapshot) -> [String] {
        var failures: [String] = []
        let names = snapshot.modules.map(\.name)
        guard names == ["aardvark", "alpha", "beta", "gamma"] else {
            return ["modules \(names), expected aardvark, alpha, beta, gamma (sorted by name, broken, nameless, hidden, \"-\" and plain folders skipped)"]
        }
        let byName = Dictionary(uniqueKeysWithValues: snapshot.modules.map { ($0.name, $0) })
        func install(_ module: String, _ project: String) -> ModuleInstall? {
            byName[module]?.installs.first { $0.projectName == project }
        }

        if let alpha = byName["alpha"] {
            let expectedEnv = [ModuleEnvVar(name: "ALPHA_KEY", required: true, description: "Signs things"),
                               ModuleEnvVar(name: "ALPHA_URL", required: false, description: "Optional base URL")]
            if alpha.version != "0.3.0" || alpha.description != "Alpha does things" { failures.append("alpha header \(alpha)") }
            if alpha.features != ["First feature", "Second feature"] { failures.append("alpha features \(alpha.features)") }
            if alpha.source != ["clients/acme", "playday"] { failures.append("alpha source \(alpha.source)") }
            if alpha.seams != ["src/lib/alpha/guard.ts"] { failures.append("alpha seams \(alpha.seams)") }
            if alpha.env != expectedEnv { failures.append("alpha env \(alpha.env)") }
            if alpha.dependencies.map(\.name) != ["postgres", "zod"] || alpha.dependencies.last?.version != "^4.0.0" {
                failures.append("alpha dependencies \(alpha.dependencies)")
            }
            if alpha.installs.count != 2 { failures.append("alpha installs \(alpha.installs.map(\.projectName))") }
            let quoted = install("alpha", "it's a project")
            if quoted?.version != "0.2.9" || quoted?.commit != "abc1234" || quoted?.isBehind != true {
                failures.append("alpha 0.2.9 against 0.3.0 should be behind: \(String(describing: quoted))")
            }
            if install("alpha", "other")?.isBehind != false {
                failures.append("alpha 0.10.0 against 0.3.0 should not be behind (numeric, not text, order)")
            }
        }

        let readmeFeatures = ["Booking form (BookingFlow)", "Slots from weekly hours: buffers and caps",
                              "sendThing() for server-side calls"]
        if byName["beta"]?.features != readmeFeatures {
            failures.append("beta README fallback \(byName["beta"]?.features ?? [])")
        }
        if byName["beta"]?.installs.count != 1 || install("beta", "it's a project")?.isBehind != false {
            failures.append("beta 1.0.0 against 1.0 should be installed and not behind")
        }
        if let gamma = byName["gamma"],
           gamma.version != nil || !gamma.features.isEmpty || !gamma.env.isEmpty || !gamma.installs.isEmpty {
            failures.append("gamma (name only) should have empty fields: \(gamma)")
        }
        // Folder zz-last holds the module named aardvark: installs are keyed by folder, and a features list that is
        // present but empty does not fall back to the README.
        if let aardvark = byName["aardvark"] {
            if aardvark.folderName != "zz-last" || !aardvark.features.isEmpty { failures.append("aardvark \(aardvark)") }
            if install("aardvark", "it's a project")?.isBehind != true || install("aardvark", "it's a project")?.version != "1.9.9" {
                failures.append("aardvark install from a plain version string: \(aardvark.installs)")
            }
        }
        if snapshot.projects.count != 4 { failures.append("projects \(snapshot.projects.map(\.name)), expected 4") }

        let missing = ModuleIndex.load(modulesFolder: snapshot.folder + "-missing", projectRoots: [])
        if !missing.modules.isEmpty { failures.append("a missing folder gave \(missing.modules.count) modules") }
        return failures
    }

    /// Install in Project offers only projects with a package.json that lack the module, and puts the deepest one
    /// holding the active session's folder first.
    private func moduleTargetFailures(_ snapshot: ModuleSnapshot, fixture: ModuleFixture) -> [String] {
        var failures: [String] = []
        let byName = Dictionary(uniqueKeysWithValues: snapshot.modules.map { ($0.name, $0) })
        guard let alpha = byName["alpha"], let gamma = byName["gamma"] else { return ["no alpha or gamma to check targets"] }
        if alpha.installTargets.map(\.project.name) != ["broken-lock"] {
            failures.append("alpha targets \(alpha.installTargets.map(\.project.name)), expected broken-lock only")
        }
        let all = ["broken-lock", "it's a project", "other"]
        if gamma.installTargets.map(\.project.name) != all {
            failures.append("gamma targets \(gamma.installTargets.map(\.project.name)), expected \(all) (no container folder)")
        }
        func pick(_ folder: String?) -> (String?, [String]) {
            let targets = ModuleActions.installTargets(for: gamma, activeDirectory: folder.map { ($0 as NSString).resolvingSymlinksInPath })
            return (targets.active?.project.name, targets.others.map(\.project.name))
        }
        let inside = pick(fixture.quotedProject + "/src")
        if inside.0 != "it's a project" || inside.1 != ["broken-lock", "other"] {
            failures.append("active session in a project's subfolder picked \(inside)")
        }
        for folder in [nil, fixture.projectsRoot, fixture.projectsRoot + "/container folder"] {
            let none = pick(folder)
            if none.0 != nil || none.1 != all { failures.append("active session in \(folder ?? "nothing") picked \(none)") }
        }
        return failures
    }

    /// What install.mjs does on Update depends on the recorded commit, and Update is never the default button.
    private func moduleUpdateAlertFailures() -> [String] {
        let module = ModuleInfo(folderName: "alpha", path: "/modules/alpha", name: "alpha", version: "0.3.0", description: nil,
                                features: [], source: [], seams: [], env: [], dependencies: [])
        func install(_ commit: String?) -> ModuleInstall {
            ModuleInstall(projectPath: "/projects/p", projectName: "p", version: "0.2.9", commit: commit, isBehind: true)
        }
        let cases: [(String?, [String], [ModuleActions.UpdateChoice], String)] = [
            ("abc1234", ["Show Changes", "Update", "Cancel"], [.showChanges, .update, .cancel], "are merged"),
            ("uncommitted", ["Cancel", "Update"], [.cancel, .update], "is overwritten"),
            (nil, ["Cancel", "Update"], [.cancel, .update], "<file>.module"),
        ]
        var failures: [String] = []
        for (commit, titles, choices, phrase) in cases {
            let (alert, actual) = ModuleActions.updateAlert(module, in: install(commit), command: "node install.mjs alpha p")
            let label = commit ?? "no commit"
            if alert.buttons.map(\.title) != titles || actual != choices {
                failures.append("update alert for \(label): buttons \(alert.buttons.map(\.title))")
            }
            // With a baseline, Show Changes takes Return. Without one, nothing does and Escape cancels.
            let returnKey = alert.buttons.filter { $0.keyEquivalent == "\r" }.map(\.title)
            let escapeKey = alert.buttons.filter { $0.keyEquivalent == "\u{1b}" }.map(\.title)
            let expectedReturn = commit == "abc1234" ? ["Show Changes"] : []
            if returnKey != expectedReturn { failures.append("update alert for \(label): Return goes to \(returnKey)") }
            if !actual.contains(.update) || escapeKey.contains("Update") {
                failures.append("update alert for \(label): Escape goes to \(escapeKey)")
            }
            if commit != "abc1234", escapeKey != ["Cancel"] {
                failures.append("update alert for \(label): Escape goes to \(escapeKey)")
            }
            if !alert.informativeText.contains(phrase) { failures.append("update alert for \(label) does not say \"\(phrase)\"") }
            if commit != "abc1234", alert.informativeText.contains("Show Changes") {
                failures.append("update alert for \(label) mentions Show Changes, which needs a commit")
            }
        }
        if !install("abc1234").hasBaseline || install("uncommitted").hasBaseline || install(nil).hasBaseline {
            failures.append("hasBaseline should hold only for a real commit")
        }
        return failures
    }

    private func moduleVersionFailures() -> [String] {
        let cases: [(String?, String?, Bool)] = [
            ("0.2.9", "0.3.0", true), ("0.10.0", "0.9.0", false), ("1.0", "1.0.0", false), ("1.0.0", "1.0.1", true),
            ("1.2.0-beta", "1.2.0", false), ("2", "10", true), (nil, "1.0.0", false), ("1.0.0", nil, false), ("x", "1", false),
        ]
        return cases.compactMap { installed, current, expected in
            ModuleIndex.isBehind(installed: installed, current: current) == expected
                ? nil : "isBehind(\(installed ?? "nil"), \(current ?? "nil")) should be \(expected)"
        }
    }

    /// The install and diff commands survive a shell intact with a space and a single quote in both paths.
    private func moduleCommandFailures(fixture: ModuleFixture, directory: String) async -> [String] {
        let project = fixture.quotedProject
        let install = ModuleIndex.installCommand(modulesFolder: fixture.modulesFolder, module: "alpha", project: project)
        let diff = ModuleIndex.diffCommand(modulesFolder: fixture.modulesFolder, module: "alpha", project: project)
        let script = fixture.modulesFolder + "/bin/install.mjs"
        let stubFolder = (directory as NSString).appendingPathComponent("stub bin")
        let stub = (stubFolder as NSString).appendingPathComponent("node")
        do {
            try FileManager.default.createDirectory(atPath: stubFolder, withIntermediateDirectories: true)
            try "#!/bin/sh\nfor arg in \"$@\"; do printf '%s\\n' \"$arg\"; done\n".write(toFile: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub)
        } catch {
            return ["stub node: \(error)"]
        }

        var failures: [String] = []
        if !install.hasPrefix("node ") || !diff.hasSuffix(" --diff") { failures.append("command shape: \(install) | \(diff)") }
        for (command, expected) in [(install, [script, "alpha", project]), (diff, [script, "alpha", project, "--diff"])] {
            let output = await Task.detached { Self.runCapturingLines(command, path: stubFolder) }.value
            if output != expected { failures.append("\(command) reached node as \(output), expected \(expected)") }
        }
        return failures
    }

    /// The library follows the setting (empty for a missing folder, which hides the sidebar section), and the
    /// Modules window and palette show what it loaded.
    private func moduleLibraryFailures(fixture: ModuleFixture, directory: String) async -> [String] {
        var failures: [String] = []
        let settings = store.settings
        let library = ModuleLibrary.shared
        // The settings live in a suite that is reset on every smoke run, so they are not put back afterwards:
        // putting them back would make the library read ~/development.
        let missing = (directory as NSString).appendingPathComponent("no modules here")
        settings.projectRoots = [fixture.projectsRoot]
        settings.modulesFolder = missing
        let emptied = await waitUntil(5) {
            library.folder == (missing as NSString).standardizingPath && library.hasLoaded && library.modules.isEmpty
        }
        if !emptied { failures.append("missing folder: library at \(library.folder) with \(library.modules.count) modules") }

        settings.modulesFolder = fixture.modulesFolder
        let loaded = await waitUntil(5) {
            library.folder == (fixture.modulesFolder as NSString).standardizingPath && library.modules.count == 4
        }
        guard loaded else {
            return failures + ["setting change: library at \(library.folder) with \(library.modules.map(\.name))"]
        }

        let controller = ModulesWindowController.shared
        controller.present(selecting: "beta")
        let shown = await waitUntil(3) { controller.window?.isVisible == true }
        if !shown || controller.model.selectedID != "beta" || controller.window?.title != "Modules" {
            failures.append("window shown \(shown), selected \(controller.model.selectedID ?? "nil")")
        }
        if controller.window?.frameAutosaveName.isEmpty == false { failures.append("a test run autosaves the Modules window frame") }
        controller.window?.close()

        // The collapsed state lives in AppSettings, so a test run writes it to the isolated suite.
        settings.modulesCollapsed = true
        let suite = UserDefaults(suiteName: ConchInfo.bundleID + ".isolated")
        if suite?.object(forKey: "conch.modulesCollapsed") as? Bool != true { failures.append("modulesCollapsed did not reach the isolated suite") }
        settings.modulesCollapsed = false

        let commands = PaletteModel(mode: .commands, store: store, projects: [])
        commands.query = "beta module"
        if commands.items.first?.id != "module:beta" { failures.append("palette top hit \(commands.items.first?.title ?? "none")") }
        commands.query = "Modules"
        if !commands.items.contains(where: { $0.id == "cmd:Modules" }) { failures.append("no Modules command in the palette") }
        // Quick Open matches the module name only and lists modules after folders and projects.
        let folders = [ProjectEntry(path: "/conch-smoke/modules", name: "modules", detail: "/conch-smoke"),
                       ProjectEntry(path: "/conch-smoke/alpha-site", name: "alpha-site", detail: "/conch-smoke")]
        let quickOpen = PaletteModel(mode: .quickOpen, store: store, projects: folders)
        quickOpen.query = "alpha"
        let ids = quickOpen.items.map(\.id)
        if let module = ids.firstIndex(of: "module:alpha"), let folder = ids.firstIndex(of: "dir:/conch-smoke/alpha-site") {
            if module < folder { failures.append("Quick Open lists the alpha module above the alpha-site folder") }
        } else {
            failures.append("Quick Open for alpha: \(ids)")
        }
        quickOpen.query = "mod"
        if quickOpen.items.contains(where: { $0.id.hasPrefix("module:") }) || !quickOpen.items.contains(where: { $0.id == "dir:/conch-smoke/modules" }) {
            failures.append("Quick Open for mod: \(quickOpen.items.map(\.id)), expected the modules folder and no modules")
        }
        return failures
    }

    /// Install, update and show changes run once in a new terminal and never again on relaunch.
    private func moduleSessionFailures(directory: String) async -> [String] {
        let session = ModuleActions.startCommandSession("echo CONCH_MODULE_$((8*2))", in: directory, name: "Install smoke")
        defer { store.close(session) }
        var failures: [String] = []
        let ran = await waitUntil(8) { session.bufferText().contains("CONCH_MODULE_16") }
        if !ran { failures.append("command session output: \(tail(session.bufferText()))") }
        if session.spec.command != nil || session.spec.cwd != directory || session.displayName != "Install smoke" {
            failures.append("command session spec \(session.spec), name \(session.displayName)")
        }
        // The install picker's Active session group follows the active session's folder.
        let model = ModulesWindowController.shared.model
        let resolved = (directory as NSString).resolvingSymlinksInPath
        if !(await waitUntil(3) { model.activeDirectory == resolved }) {
            failures.append("Modules window active folder \(model.activeDirectory ?? "nil"), expected \(resolved)")
        }
        return failures
    }

    /// Window > Modules is ⇧⌘M, and nothing else in the menu bar uses that shortcut.
    private func moduleMenuFailures() -> [String] {
        func allItems(_ menu: NSMenu?) -> [NSMenuItem] {
            (menu?.items ?? []).flatMap { [$0] + allItems($0.submenu) }
        }
        func shortcut(_ item: NSMenuItem) -> String? {
            guard !item.keyEquivalent.isEmpty else { return nil }
            var modifiers = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
            if item.keyEquivalent != item.keyEquivalent.lowercased() { modifiers.insert(.shift) }
            return "\(modifiers.rawValue):\(item.keyEquivalent.lowercased())"
        }
        let items = allItems(NSApp.mainMenu)
        guard let modules = items.first(where: { $0.title == "Modules" && $0.action == #selector(ModulesMenuTarget.showModules(_:)) }),
              let key = shortcut(modules) else {
            return ["no Modules menu item with a shortcut"]
        }
        var failures: [String] = []
        if key != "\(NSEvent.ModifierFlags([.command, .shift]).rawValue):m" { failures.append("Modules shortcut \(key)") }
        let clashes = items.filter { $0 !== modules && shortcut($0) == key }.map(\.title)
        if !clashes.isEmpty { failures.append("⇧⌘M also used by \(clashes)") }
        return failures
    }

    /// Runs `command` with zsh, with `path` first on PATH, and returns its output lines.
    nonisolated private static func runCapturingLines(_ command: String, path: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", command]
        process.environment = ["PATH": path + ":/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return ["could not run zsh: \(error)"] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).filter { !$0.isEmpty }
    }
}

/// The throwaway folders check 16 reads.
private struct ModuleFixture {
    let modulesFolder: String
    let projectsRoot: String

    var quotedProject: String { (projectsRoot as NSString).appendingPathComponent("it's a project") }

    func write() -> String? {
        let betaReadme = """
            Beta

            Intro paragraph with - not a bullet.

            ```
            - not this, it is inside a code fence
            ```

            What you get

            - Booking form (`BookingFlow`). Extra sentence here.
              - Indented child, skipped
            - Slots from weekly hours: buffers and caps.

            - `sendThing()` for server-side calls
            Files

            - not this one, it is a second list
            """
        let files: [(String, String)] = [
            ("\(modulesFolder)/alpha/module.json", """
                {"name": "alpha", "version": "0.3.0", "description": "Alpha does things",
                 "features": ["First feature", "Second feature"], "source": ["clients/acme", "playday"],
                 "seams": ["src/lib/alpha/guard.ts"],
                 "env": [{"name": "ALPHA_KEY", "required": true, "description": "Signs things"},
                         {"name": "ALPHA_URL", "description": "Optional base URL"}],
                 "dependencies": {"zod": "^4.0.0", "postgres": "^3.4.8"}, "files": ["x"], "somethingNew": {"a": 1}}
                """),
            ("\(modulesFolder)/beta/module.json", #"{"name": "beta", "version": "1.0"}"#),
            ("\(modulesFolder)/beta/README.md", betaReadme),
            ("\(modulesFolder)/gamma/module.json", #"{"name": "gamma"}"#),
            ("\(modulesFolder)/zz-last/module.json", #"{"name": "aardvark", "version": "2.0.0", "features": []}"#),
            ("\(modulesFolder)/zz-last/README.md", "- A bullet that must not be used\n"),
            ("\(modulesFolder)/broken/module.json", #"{"name": "broken", "version": "#),
            ("\(modulesFolder)/nameless/module.json", #"{"version": "1.0.0"}"#),
            ("\(modulesFolder)/.hidden/module.json", #"{"name": "hidden"}"#),
            ("\(modulesFolder)/plain folder/notes.txt", "no manifest here"),
            ("\(modulesFolder)/-flag/module.json", #"{"name": "flag"}"#),
            ("\(quotedProject)/package.json", "{}"),
            ("\(quotedProject)/src/index.ts", ""),
            ("\(quotedProject)/modules.json", """
                {"alpha": {"version": "0.2.9", "commit": "abc1234"}, "beta": {"version": "1.0.0", "commit": "def5678"},
                 "zz-last": "1.9.9", "unknown-module": {"version": "9"}}
                """),
            ("\(projectsRoot)/other/package.json", "{}"),
            ("\(projectsRoot)/other/modules.json", #"{"alpha": {"version": "0.10.0"}}"#),
            ("\(projectsRoot)/broken-lock/package.json", "{}"),
            ("\(projectsRoot)/broken-lock/modules.json", "{not json"),
            ("\(projectsRoot)/container folder/notes.txt", "a folder directly in the root, without a package.json"),
        ]
        do {
            for (path, contents) in files {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                        withIntermediateDirectories: true)
                try contents.write(toFile: path, atomically: true, encoding: .utf8)
            }
        } catch {
            return "\(error)"
        }
        return nil
    }
}
