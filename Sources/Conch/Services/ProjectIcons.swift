import AppKit
import ImageIO
import UniformTypeIdentifiers

// Owner: project icons builder (feature/older-section follow-on).

/// What a sidebar row shows for its project: a picture (the user's own, or one found in the project) or an emoji.
enum ProjectIcon {
    case image(NSImage, custom: Bool)
    case emoji(String)
}

/// One custom icon, as project-icons.json stores it: the file name of a copy in project-icons/, or an emoji.
struct ProjectIconChoice: Codable, Equatable {
    var image: String?
    var emoji: String?
}

/// Project icons for the sidebar. A custom icon the user set wins, else an icon found in the project itself (looked
/// up once per project, off the main thread), else none. Custom icons live next to the state file: the mapping in
/// project-icons.json keyed by resolved project root, and downscaled copies of chosen images in project-icons/, so
/// the original can move.
@MainActor
final class ProjectIcons: ObservableObject {
    static let shared = ProjectIcons(folder: Persistence.stateURL.deletingLastPathComponent())

    /// The folder holding project-icons.json and project-icons/.
    let folder: URL
    var mappingURL: URL { folder.appendingPathComponent("project-icons.json") }
    var imagesFolder: URL { folder.appendingPathComponent("project-icons", isDirectory: true) }

    private var choices: [String: ProjectIconChoice]
    private var customImages: [String: NSImage] = [:]
    /// Lookup results per root. An entry holding nil means the project has no icon of its own.
    private var found: [String: NSImage?] = [:]
    private var lookups: [String: Task<Void, Never>] = [:]
    private var keys: [String: String] = [:]

    /// Copies are at most this many pixels on their longer side.
    nonisolated static let maxCopyPixels = 64
    /// Found icons are decoded at this size: 16 pt on a Retina screen.
    nonisolated private static let displayPixels = 32
    static let imageTypes: [UTType] = [.png, .jpeg, .heic, .ico, .icns]

    /// Checked in this order in the project root, then in each of `subfolders`, for projects that keep the app in a
    /// subfolder.
    nonisolated static let candidates = [
        "app/icon.png", "src/app/icon.png", "app/apple-icon.png", "public/apple-touch-icon.png", "public/icon.png",
        "public/logo.png", "public/favicon.png", "app/favicon.ico", "src/app/favicon.ico", "public/favicon.ico",
    ]
    nonisolated static let subfolders = ["site", "web", "app"]
    /// Reading these makes macOS ask for permission, so projects inside them get no lookup.
    nonisolated private static let protectedHomeFolders = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies", "Library"]

    init(folder: URL) {
        self.folder = folder
        let url = folder.appendingPathComponent("project-icons.json")
        choices = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: ProjectIconChoice].self, from: $0) } ?? [:]
    }

    // MARK: Reading

    /// The icon for a project root, nil while the project's own icon is being looked up or when it has none.
    /// Starts that lookup the first time a root is asked for, and publishes once it finishes.
    func icon(forRoot root: String) -> ProjectIcon? {
        let key = key(for: root)
        if let choice = choices[key] {
            if let emoji = choice.emoji { return .emoji(emoji) }
            if let image = customImage(key: key, file: choice.image) { return .image(image, custom: true) }
        }
        if let image = found[key] { return image.map { .image($0, custom: false) } }
        startLookup(key)
        return nil
    }

    /// The custom icon set for a project root, nil when it shows its own (or none).
    func choice(forRoot root: String) -> ProjectIconChoice? { choices[key(for: root)] }

    /// Waits for the lookup of a root's own icon and returns the file it found. For the smoke test.
    func lookupFinished(forRoot root: String) async {
        let key = key(for: root)
        startLookup(key)
        await lookups[key]?.value
    }

    // MARK: Setting

    /// Copies a downscaled PNG of the image into project-icons/ and makes it the root's icon. False when the file is
    /// not an image ImageIO can read.
    @discardableResult
    func setImage(from source: URL, forRoot root: String) async -> Bool {
        let key = key(for: root)
        let destination = imagesFolder.appendingPathComponent(UUID().uuidString + ".png")
        let written = await Task.detached(priority: .userInitiated) {
            Self.writeCopy(of: source, to: destination, maxPixels: Self.maxCopyPixels)
        }.value
        guard written else { return false }
        removeCopy(of: key)
        choices[key] = ProjectIconChoice(image: destination.lastPathComponent)
        saveChoices()
        return true
    }

    /// Makes the first character of `text` the root's icon when it is an emoji. False otherwise.
    @discardableResult
    func setEmoji(_ text: String, forRoot root: String) -> Bool {
        guard let emoji = Self.firstEmoji(in: text) else { return false }
        let key = key(for: root)
        removeCopy(of: key)
        choices[key] = ProjectIconChoice(emoji: emoji)
        saveChoices()
        return true
    }

    /// Drops the custom icon, so the project's own icon (or none) shows again.
    func removeIcon(forRoot root: String) {
        let key = key(for: root)
        guard choices[key] != nil else { return }
        removeCopy(of: key)
        choices[key] = nil
        saveChoices()
    }

    /// The first character of the text when it is an emoji: one shown as emoji by default, or one with more than one
    /// scalar (a variation selector, a skin tone, a flag or a joined sequence).
    nonisolated static func firstEmoji(in text: String) -> String? {
        guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        let scalars = first.unicodeScalars
        let isEmoji = scalars.contains { $0.properties.isEmojiPresentation }
            || (scalars.count > 1 && scalars.contains { $0.properties.isEmoji })
        return isEmoji ? String(first) : nil
    }

    // MARK: Project lookup

    /// The project's own icon file: the first of `candidates` in the root, then in each of `subfolders`. nil for a
    /// project in a privacy-protected folder, which is never read. Blocking: call it off the main thread.
    nonisolated static func findIcon(inProject root: String) -> String? {
        guard !isProtected(root) else { return nil }
        let bases = [root] + subfolders.map { (root as NSString).appendingPathComponent($0) }
        for base in bases {
            for candidate in candidates {
                let path = (base as NSString).appendingPathComponent(candidate)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    return path
                }
            }
        }
        return nil
    }

    /// Inside Desktop, Documents, Downloads, Pictures, Music, Movies or Library in the home folder, or on another
    /// volume. Matched on the path alone, without touching the disk.
    nonisolated static func isProtected(_ path: String) -> Bool {
        let standard = (path as NSString).standardizingPath
        if standard == "/Volumes" || standard.hasPrefix("/Volumes/") { return true }
        let home = NSHomeDirectory()
        return protectedHomeFolders.contains { folder in
            let protected = (home as NSString).appendingPathComponent(folder)
            return standard == protected || standard.hasPrefix(protected + "/")
        }
    }

    // MARK: Private

    /// The resolved project root, the key in project-icons.json. Symlinks are resolved only outside protected
    /// folders, because resolving reads the disk.
    private func key(for root: String) -> String {
        if let cached = keys[root] { return cached }
        let standard = (root as NSString).standardizingPath
        let key = Self.isProtected(standard) ? standard : URL(fileURLWithPath: standard).resolvingSymlinksInPath().path
        keys[root] = key
        return key
    }

    private func startLookup(_ key: String) {
        guard found[key] == nil, lookups[key] == nil else { return }
        lookups[key] = Task { [weak self] in
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let path = Self.findIcon(inProject: key) else { return nil }
                return Self.thumbnail(of: URL(fileURLWithPath: path), maxPixels: Self.displayPixels)
            }.value
            guard let self else { return }
            self.objectWillChange.send()
            self.found[key] = .some(image.map { NSImage(cgImage: $0, size: NSSize(width: 16, height: 16)) })
        }
    }

    private func customImage(key: String, file: String?) -> NSImage? {
        if let image = customImages[key] { return image }
        guard let file, let image = NSImage(contentsOf: imagesFolder.appendingPathComponent(file)) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        customImages[key] = image
        return image
    }

    private func removeCopy(of key: String) {
        customImages[key] = nil
        if let file = choices[key]?.image {
            try? FileManager.default.removeItem(at: imagesFolder.appendingPathComponent(file))
        }
    }

    private func saveChoices() {
        objectWillChange.send()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(choices).write(to: mappingURL, options: .atomic)
        } catch {
            NSLog("Conch: could not save project icons to %@: %@", mappingURL.path, error.localizedDescription)
        }
    }

    /// The largest picture in the file (an .ico or .icns holds several), scaled to fit `maxPixels`, never enlarged.
    nonisolated static func thumbnail(of url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var best = 0
        var bestSide = 0
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let side = max(properties?[kCGImagePropertyPixelWidth] as? Int ?? 0, properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
            if side > bestSide { (best, bestSide) = (index, side) }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: bestSide > 0 ? min(maxPixels, bestSide) : maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, best, options as CFDictionary)
    }

    nonisolated private static func writeCopy(of source: URL, to destination: URL, maxPixels: Int) -> Bool {
        guard let image = thumbnail(of: source, maxPixels: maxPixels) else { return false }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(output, image, nil)
        return CGImageDestinationFinalize(output)
    }
}
