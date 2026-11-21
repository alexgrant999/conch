import AppKit
import Combine

// Owner: modules builder (feature/modules-section).

struct ModuleEnvVar: Equatable, Hashable {
    var name: String
    var required: Bool
    var description: String
}

struct ModuleDependency: Equatable, Hashable {
    var name: String
    var version: String
}

/// A project that has the module installed, from the `modules.json` at its root.
struct ModuleInstall: Equatable, Identifiable {
    var projectPath: String
    var projectName: String
    var version: String?
    var commit: String?
    /// The recorded version is lower than the module's current one.
    var isBehind: Bool
    var id: String { projectPath }

    /// What install.mjs records for an install made with --allow-dirty.
    static let uncommittedCommit = "uncommitted"

    /// install.mjs merges an update and shows changes only against a recorded commit. Without one ("uncommitted",
    /// or no commit at all) there is nothing to compare with.
    var hasBaseline: Bool { commit != nil && commit != Self.uncommittedCommit }
}

/// A project the install picker offers.
struct InstallTarget: Equatable, Identifiable {
    var project: ProjectEntry
    /// `project.path` with symlinks resolved, to match the active session's folder against.
    var resolvedPath: String
    var id: String { project.path }
}

/// One module folder: its module.json, plus the projects that installed it.
struct ModuleInfo: Equatable, Identifiable {
    /// Folder name. install.mjs takes this as its module argument and keys modules.json by it.
    var folderName: String
    /// Absolute path of the module folder.
    var path: String
    var name: String
    var version: String?
    var description: String?
    var features: [String]
    /// Paths relative to the folder that holds the modules folder, for example "clients/acme".
    var source: [String]
    var seams: [String]
    var env: [ModuleEnvVar]
    var dependencies: [ModuleDependency]
    var installs: [ModuleInstall] = []
    /// Projects the module can be installed in, by name: the scanned ones with a package.json that do not have it.
    var installTargets: [InstallTarget] = []

    var id: String { folderName }
    var readmePath: String { (path as NSString).appendingPathComponent("README.md") }
    var behindCount: Int { installs.filter(\.isBehind).count }
}

struct ModuleSnapshot {
    /// The modules folder, tilde expanded.
    var folder: String
    var modules: [ModuleInfo]
    /// Every project the scan found.
    var projects: [ProjectEntry]
}

/// Reads the modules folder and the projects that installed each module. Everything here is blocking file IO,
/// so call it off the main thread.
enum ModuleIndex {
    /// Modules in `modulesFolder` with their installs across the projects `ProjectScanner` finds in `projectRoots`.
    static func load(modulesFolder: String, projectRoots: [String]) -> ModuleSnapshot {
        let folder = (modulesFolder.expandingTilde as NSString).standardizingPath
        let modules = loadModules(in: folder)
        guard !modules.isEmpty else { return ModuleSnapshot(folder: folder, modules: [], projects: []) }
        let projects = ProjectScanner.scan(roots: projectRoots).filter { $0.path != folder }
        let withInstalls = attachInstalls(to: modules, projects: projects)
        return ModuleSnapshot(folder: folder, modules: attachInstallTargets(to: withInstalls, projects: projects),
                              projects: projects)
    }

    /// Each child folder with a readable module.json that has a name, sorted by name. Hidden folders, folders
    /// whose name starts with "-" (install.mjs would read it as a flag) and malformed manifests are skipped, and so
    /// are Desktop, Documents and the other privacy-protected folders when `folder` is the home folder.
    static func loadModules(in folder: String) -> [ModuleInfo] {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(atPath: folder) else { return [] }
        let isHome = folder == (NSHomeDirectory() as NSString).standardizingPath
        var modules: [ModuleInfo] = []
        for child in children where !child.hasPrefix(".") && !child.hasPrefix("-")
            && !(isHome && ProjectScanner.protectedHomeFolders.contains(child)) {
            let path = (folder as NSString).appendingPathComponent(child)
            let manifest = (path as NSString).appendingPathComponent("module.json")
            guard let data = fileManager.contents(atPath: manifest),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let module = parseManifest(json, folderName: child, path: path) else { continue }
            modules.append(module)
        }
        return modules.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.folderName < $1.folderName : order == .orderedAscending
        }
    }

    /// nil without a non-empty string `name`. Every other field is optional, and unknown fields are ignored.
    static func parseManifest(_ json: [String: Any], folderName: String, path: String) -> ModuleInfo? {
        guard let name = nonEmpty(json["name"]) else { return nil }
        let features: [String]
        if let listed = json["features"] as? [Any] {
            features = listed.compactMap(nonEmpty)
        } else {
            let readme = (path as NSString).appendingPathComponent("README.md")
            features = (try? String(contentsOfFile: readme, encoding: .utf8)).map(features(fromReadme:)) ?? []
        }
        let env: [ModuleEnvVar] = (json["env"] as? [Any] ?? []).compactMap { entry in
            if let name = nonEmpty(entry) { return ModuleEnvVar(name: name, required: false, description: "") }
            guard let object = entry as? [String: Any], let name = nonEmpty(object["name"]) else { return nil }
            return ModuleEnvVar(name: name, required: object["required"] as? Bool ?? false,
                                description: nonEmpty(object["description"]) ?? "")
        }
        let dependencies = (json["dependencies"] as? [String: Any] ?? [:])
            .map { ModuleDependency(name: $0.key, version: nonEmpty($0.value) ?? "\($0.value)") }
            .sorted { $0.name < $1.name }
        return ModuleInfo(folderName: folderName, path: path, name: name,
                          version: nonEmpty(json["version"]), description: nonEmpty(json["description"]),
                          features: features, source: stringList(json["source"]), seams: stringList(json["seams"]),
                          env: env, dependencies: dependencies)
    }

    /// The first run of top-level "- " bullets, first sentence of each, backticks stripped. Indented lines (sub
    /// bullets, wrapped text) and blank lines inside the run are skipped. Code fences are ignored.
    static func features(fromReadme text: String) -> [String] {
        var features: [String] = []
        var inFence = false
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                if !features.isEmpty { break }
                continue
            }
            if inFence { continue }
            if line.hasPrefix("- ") {
                let sentence = firstSentence(String(line.dropFirst(2)).replacingOccurrences(of: "`", with: ""))
                if !sentence.isEmpty { features.append(sentence) }
            } else if !features.isEmpty, !line.isEmpty, !(line.first?.isWhitespace ?? false) {
                break
            }
        }
        return features
    }

    /// Matches each project's modules.json against the modules, by folder name (what install.mjs records) or name.
    static func attachInstalls(to modules: [ModuleInfo], projects: [ProjectEntry]) -> [ModuleInfo] {
        var result = modules
        for project in projects {
            let lockPath = (project.path as NSString).appendingPathComponent("modules.json")
            guard let data = FileManager.default.contents(atPath: lockPath),
                  let lock = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for index in result.indices {
                let module = result[index]
                guard let entry = lock[module.folderName] ?? lock[module.name] else { continue }
                let record = entry as? [String: Any]
                let version = nonEmpty(record?["version"]) ?? nonEmpty(entry)
                result[index].installs.append(ModuleInstall(
                    projectPath: project.path, projectName: project.name, version: version,
                    commit: nonEmpty(record?["commit"]), isBehind: isBehind(installed: version, current: module.version)
                ))
            }
        }
        return result
    }

    /// Fills each module's install targets: projects with a package.json at their root (ProjectScanner also lists
    /// container folders such as clients or Archive), without the ones that have the module. Symlinks are resolved
    /// here, off the main thread.
    static func attachInstallTargets(to modules: [ModuleInfo], projects: [ProjectEntry]) -> [ModuleInfo] {
        let fileManager = FileManager.default
        let targets = projects
            .filter { fileManager.fileExists(atPath: ($0.path as NSString).appendingPathComponent("package.json")) }
            .map { InstallTarget(project: $0, resolvedPath: ($0.path as NSString).resolvingSymlinksInPath) }
        return modules.map { module in
            var module = module
            let installed = Set(module.installs.map { ($0.projectPath as NSString).resolvingSymlinksInPath })
            module.installTargets = targets.filter { !installed.contains($0.resolvedPath) }
            return module
        }
    }

    /// True when `installed` is a lower dotted version than `current`. Unknown or unreadable versions are never behind.
    static func isBehind(installed: String?, current: String?) -> Bool {
        guard let installed, let current else { return false }
        let (have, want) = (versionNumbers(installed), versionNumbers(current))
        guard !have.isEmpty, !want.isEmpty else { return false }
        for index in 0..<max(have.count, want.count) {
            let (left, right) = (index < have.count ? have[index] : 0, index < want.count ? want[index] : 0)
            if left != right { return left < right }
        }
        return false
    }

    /// `node <folder>/bin/install.mjs <module> <project>`, each word shell quoted.
    static func installCommand(modulesFolder: String, module: String, project: String) -> String {
        let script = ((modulesFolder.expandingTilde as NSString).appendingPathComponent("bin") as NSString)
            .appendingPathComponent("install.mjs")
        return ["node", script, module, project].map(LaunchCommand.shellQuote).joined(separator: " ")
    }

    /// The install command with `--diff`: what the project changed in the module's files since it installed them.
    static func diffCommand(modulesFolder: String, module: String, project: String) -> String {
        installCommand(modulesFolder: modulesFolder, module: module, project: project) + " --diff"
    }

    // MARK: - Helpers

    /// "1.2.0-beta" gives [1, 2, 0]: the leading digits of each dotted part, stopping at the first part without any.
    private static func versionNumbers(_ version: String) -> [Int] {
        var numbers: [Int] = []
        for part in version.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false) {
            guard let number = Int(part.prefix(while: \.isASCII).prefix(while: \.isNumber)) else { break }
            numbers.append(number)
        }
        return numbers
    }

    private static func firstSentence(_ text: String) -> String {
        var sentence = text.trimmingCharacters(in: .whitespaces)
        if let end = sentence.range(of: ". ") { sentence = String(sentence[..<end.lowerBound]) }
        while let last = sentence.last, last == "." || last == ":" { sentence.removeLast() }
        return sentence.trimmingCharacters(in: .whitespaces)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let single = nonEmpty(value) { return [single] }
        return (value as? [Any] ?? []).compactMap(nonEmpty)
    }
}

/// The module list the sidebar, the Modules window and the palette show. Reloads when the app becomes active, when
/// the modules folder or project folders setting changes, and when the Modules window opens or becomes key.
/// No timers: between those events the list stays as it was.
@MainActor
final class ModuleLibrary: ObservableObject {
    static let shared = ModuleLibrary(settings: .shared)

    @Published private(set) var modules: [ModuleInfo] = []
    /// The folder `modules` came from, tilde expanded. Empty before the first load.
    @Published private(set) var folder = ""
    /// False until the first load finishes.
    @Published private(set) var hasLoaded = false

    private let settings: AppSettings
    private var cancellables: Set<AnyCancellable> = []
    private var isLoading = false
    private var reloadWhenDone = false

    init(settings: AppSettings) {
        self.settings = settings
        settings.$modulesFolder.combineLatest(settings.$projectRoots)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
        // The smoke test points the settings at a throwaway folder itself, so it never reads ~/development.
        guard SmokeTest.resultPath(in: CommandLine.arguments) == nil else { return }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
        reload()
    }

    func module(withID id: String) -> ModuleInfo? { modules.first { $0.id == id } }

    /// Starts a reload off the main thread. A call while one runs queues exactly one more.
    func reload() {
        guard !isLoading else {
            reloadWhenDone = true
            return
        }
        isLoading = true
        let folder = settings.modulesFolder
        let roots = settings.projectRoots
        Task.detached(priority: .userInitiated) { [weak self] in
            let snapshot = ModuleIndex.load(modulesFolder: folder, projectRoots: roots)
            await self?.apply(snapshot)
        }
    }

    private func apply(_ snapshot: ModuleSnapshot) {
        isLoading = false
        if modules != snapshot.modules { modules = snapshot.modules }
        if folder != snapshot.folder { folder = snapshot.folder }
        if !hasLoaded { hasLoaded = true }
        if reloadWhenDone {
            reloadWhenDone = false
            reload()
        }
    }
}
