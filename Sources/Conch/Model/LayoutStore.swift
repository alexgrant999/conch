import Foundation

// Owner: layouts builder (feature/layouts).

/// Saved project layouts, at most one per project root, in layouts.json next to the state file (so
/// CONCH_STATE_PATH isolates it as well).
@MainActor
final class LayoutStore {
    static let shared = LayoutStore()

    private var cache: (url: URL, layouts: [ProjectLayout])?

    var fileURL: URL {
        Persistence.stateURL.deletingLastPathComponent().appendingPathComponent("layouts.json")
    }

    /// Sorted by name.
    var layouts: [ProjectLayout] {
        let url = fileURL
        if let cache, cache.url == url { return cache.layouts }
        let loaded = Self.read(from: url)
        cache = (url, loaded)
        return loaded
    }

    func layout(forRoot root: String) -> ProjectLayout? {
        layouts.first { $0.root == root }
    }

    /// Adds the layout, replacing the one saved for the same root.
    func save(_ layout: ProjectLayout) {
        write(layouts.filter { $0.root != layout.root && $0.id != layout.id } + [layout])
    }

    func delete(id: UUID) {
        write(layouts.filter { $0.id != id })
    }

    /// Empty when the file is missing. A file that does not decode is moved aside first, so the next save does not
    /// silently replace layouts someone edited by hand.
    static func read(from url: URL) -> [ProjectLayout] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode(LayoutFile.self, from: data).layouts
        } catch {
            let aside = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            NSLog("Conch: could not read %@ (%@), moved it to %@", url.path, error.localizedDescription, aside.lastPathComponent)
            return []
        }
    }

    private func write(_ list: [ProjectLayout]) {
        let url = fileURL
        let sorted = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cache = (url, sorted)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(LayoutFile(layouts: sorted)).write(to: url, options: .atomic)
        } catch {
            NSLog("Conch: could not save layouts to %@: %@", url.path, error.localizedDescription)
        }
    }
}

private struct LayoutFile: Codable {
    var version = 1
    var layouts: [ProjectLayout]
}
