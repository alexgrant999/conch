import Foundation

enum Persistence {
    /// ~/Library/Application Support/Conch/state.json, or the path in the CONCH_STATE_PATH environment variable
    /// when set (the smoke test uses this so it never touches real state).
    static var stateURL: URL {
        if let override = ProcessInfo.processInfo.environment["CONCH_STATE_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override.expandingTilde)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(ConchInfo.appName, isDirectory: true)
            .appendingPathComponent("state.json")
    }

    /// nil when missing or unreadable.
    static func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    /// Takes an exclusive lock next to the state file for the life of the process, so a second Conch on the same
    /// state cannot resume the same Claude sessions again and overwrite this one's saves. False when another
    /// process holds it. The descriptor is left open on purpose: closing it would release the lock.
    static func acquireInstanceLock() -> Bool {
        let url = stateURL.appendingPathExtension("lock")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
        close(fd)
        return false
    }

    /// Atomic write. Creates the folder when needed.
    static func save(_ state: PersistedState) {
        let url = stateURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            NSLog("Conch: could not save state to %@: %@", url.path, error.localizedDescription)
        }
    }
}
