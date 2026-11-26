import Foundation
import Combine

/// Every property persists to UserDefaults (keys prefixed "conch.") on change.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings(defaults: launchDefaults())

    /// Default 13.
    @Published var fontSize: Double = 13 {
        didSet { defaults.set(fontSize, forKey: Key.fontSize) }
    }
    /// Default true. Option sends Meta (needed for Option+Return newline and word motions in Claude Code).
    @Published var optionAsMeta: Bool = true {
        didSet { defaults.set(optionAsMeta, forKey: Key.optionAsMeta) }
    }
    /// Default true. New Claude sessions start with `--remote-control` so they show in claude.ai/code.
    @Published var remoteControlByDefault: Bool = true {
        didSet { defaults.set(remoteControlByDefault, forKey: Key.remoteControlByDefault) }
    }
    /// Model new Claude sessions start with, the `model` of one of `ClaudeModels.all` (a family alias or a specific
    /// model id). "" (the default) leaves it to Claude Code's own default.
    @Published var defaultModel: String = "" {
        didSet { defaults.set(defaultModel, forKey: Key.defaultModel) }
    }
    /// Default true. Plan limits and the last prompt's cost at the trailing end of the main window's toolbar.
    @Published var showUsageInToolbar: Bool = true {
        didSet { defaults.set(showUsageInToolbar, forKey: Key.showUsageInToolbar) }
    }
    /// Default true. Copy in a Claude session drops the indent and rejoins the lines Claude Code wrapped.
    @Published var cleanCopiedText: Bool = true {
        didSet { defaults.set(cleanCopiedText, forKey: Key.cleanCopiedText) }
    }
    /// Default true.
    @Published var restoreSessionsOnLaunch: Bool = true {
        didSet { defaults.set(restoreSessionsOnLaunch, forKey: Key.restoreSessionsOnLaunch) }
    }
    /// Default true. macOS notification when a busy session goes quiet while not visible.
    @Published var notifyWhenDone: Bool = true {
        didSet { defaults.set(notifyWhenDone, forKey: Key.notifyWhenDone) }
    }
    /// Default true. macOS notification on bell or OSC desktop notification while not visible.
    @Published var notifyOnBell: Bool = true {
        didSet { defaults.set(notifyOnBell, forKey: Key.notifyOnBell) }
    }
    /// Default true. Menu bar item with the number of sessions waiting for you.
    @Published var showInMenuBar: Bool = true {
        didSet { defaults.set(showInMenuBar, forKey: Key.showInMenuBar) }
    }
    /// Hours without use before a session group moves to the sidebar's Older section, one of `olderAfterChoices`.
    /// 0 turns the section off. Default 6.
    @Published var olderAfterHours: Int = 6 {
        didSet { defaults.set(olderAfterHours, forKey: Key.olderAfterHours) }
    }
    static let olderAfterChoices = [0, 1, 3, 6, 12, 24]
    /// Folders scanned for projects in Quick Open. Default ["~/development"]. Stored with tildes, expand on use.
    @Published var projectRoots: [String] = ["~/development"] {
        didSet { defaults.set(projectRoots, forKey: Key.projectRoots) }
    }
    /// Folder of reusable feature modules shown in the sidebar's Modules section. Default "~/development/modules".
    /// Stored with a tilde, expand on use.
    @Published var modulesFolder: String = "~/development/modules" {
        didSet { defaults.set(modulesFolder, forKey: Key.modulesFolder) }
    }
    /// Default false. The sidebar's Modules section shows only its header.
    @Published var modulesCollapsed: Bool = false {
        didSet { defaults.set(modulesCollapsed, forKey: Key.modulesCollapsed) }
    }
    /// Where new sessions start when nothing is active. Default "~/development" if it exists, else "~".
    @Published var defaultDirectory: String = "~" {
        didSet { defaults.set(defaultDirectory, forKey: Key.defaultDirectory) }
    }
    /// Most recent first, max 20, absolute paths, de-duplicated.
    @Published private(set) var recentDirectories: [String] = [] {
        didSet { defaults.set(recentDirectories, forKey: Key.recentDirectories) }
    }

    private let defaults: UserDefaults
    private static let maxRecentDirectories = 20

    private enum Key {
        static let fontSize = "conch.fontSize"
        static let optionAsMeta = "conch.optionAsMeta"
        static let remoteControlByDefault = "conch.remoteControlByDefault"
        static let defaultModel = "conch.defaultModel"
        static let showUsageInToolbar = "conch.showUsageInToolbar"
        static let cleanCopiedText = "conch.cleanCopiedText"
        static let restoreSessionsOnLaunch = "conch.restoreSessionsOnLaunch"
        static let notifyWhenDone = "conch.notifyWhenDone"
        static let notifyOnBell = "conch.notifyOnBell"
        static let showInMenuBar = "conch.showInMenuBar"
        static let olderAfterHours = "conch.olderAfterHours"
        static let projectRoots = "conch.projectRoots"
        static let defaultDirectory = "conch.defaultDirectory"
        static let modulesFolder = "conch.modulesFolder"
        static let modulesCollapsed = "conch.modulesCollapsed"
        static let recentDirectories = "conch.recentDirectories"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let value = defaults.object(forKey: Key.fontSize) as? Double, value.isFinite, (6...72).contains(value) {
            fontSize = value
        }
        if let value = defaults.object(forKey: Key.optionAsMeta) as? Bool { optionAsMeta = value }
        if let value = defaults.object(forKey: Key.remoteControlByDefault) as? Bool { remoteControlByDefault = value }
        if let value = defaults.string(forKey: Key.defaultModel), ClaudeModels.all.contains(where: { $0.model == value }) {
            defaultModel = value
        }
        if let value = defaults.object(forKey: Key.showUsageInToolbar) as? Bool { showUsageInToolbar = value }
        if let value = defaults.object(forKey: Key.cleanCopiedText) as? Bool { cleanCopiedText = value }
        if let value = defaults.object(forKey: Key.restoreSessionsOnLaunch) as? Bool { restoreSessionsOnLaunch = value }
        if let value = defaults.object(forKey: Key.notifyWhenDone) as? Bool { notifyWhenDone = value }
        if let value = defaults.object(forKey: Key.notifyOnBell) as? Bool { notifyOnBell = value }
        if let value = defaults.object(forKey: Key.showInMenuBar) as? Bool { showInMenuBar = value }
        if let value = defaults.object(forKey: Key.olderAfterHours) as? Int, Self.olderAfterChoices.contains(value) {
            olderAfterHours = value
        }
        if let value = defaults.stringArray(forKey: Key.projectRoots) { projectRoots = value }
        if let value = defaults.string(forKey: Key.modulesFolder), !value.isEmpty { modulesFolder = value }
        if let value = defaults.object(forKey: Key.modulesCollapsed) as? Bool { modulesCollapsed = value }

        if let value = defaults.string(forKey: Key.defaultDirectory), !value.isEmpty {
            defaultDirectory = value
        } else {
            defaultDirectory = Self.isDirectory("~/development".expandingTilde) ? "~/development" : "~"
        }

        var recents: [String] = []
        for path in defaults.stringArray(forKey: Key.recentDirectories) ?? []
        where path.hasPrefix("/") && !recents.contains(path) && Self.isDirectory(path) {
            recents.append(path)
        }
        recentDirectories = Array(recents.prefix(Self.maxRecentDirectories))
    }

    func noteRecentDirectory(_ path: String) {
        let absolute = (path.expandingTilde as NSString).standardizingPath
        guard absolute.hasPrefix("/") else { return }
        var list = recentDirectories.filter { $0 != absolute }
        list.insert(absolute, at: 0)
        list = Array(list.prefix(Self.maxRecentDirectories))
        if list != recentDirectories { recentDirectories = list }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // With CONCH_STATE_PATH set (the smoke test, or a throwaway second instance) settings live in their own suite,
    // reset on every launch, so test runs neither read the user's settings nor pollute recentDirectories.
    private static func launchDefaults() -> UserDefaults {
        guard let statePath = ProcessInfo.processInfo.environment["CONCH_STATE_PATH"], !statePath.isEmpty else {
            return .standard
        }
        let suite = ConchInfo.bundleID + ".isolated"
        guard let isolated = UserDefaults(suiteName: suite) else { return .standard }
        isolated.removePersistentDomain(forName: suite)
        return isolated
    }
}
