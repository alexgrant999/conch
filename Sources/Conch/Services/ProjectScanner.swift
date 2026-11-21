import Foundation

struct ProjectEntry: Identifiable, Hashable {
    /// Absolute path.
    let path: String
    /// Folder name.
    let name: String
    /// Parent path abbreviated with "~", for display under the name.
    let detail: String
    var id: String { path }
}

enum ProjectScanner {
    private static let markers: Set<String> = [
        ".git", "package.json", "Package.swift", "pubspec.yaml", "Cargo.toml", "pyproject.toml", "go.mod", "CLAUDE.md",
    ]
    private static let skippedFolders: Set<String> = [
        "node_modules", ".build", ".next", "dist", "build", "Pods", "vendor", "Library",
    ]
    /// Listing these triggers a macOS privacy prompt for Conch, so a scan of the home folder leaves them alone.
    static let protectedHomeFolders: Set<String> = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies"]
    private static let childKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]

    /// Walks each root (tilde expanded) up to `maxDepth` levels and returns every folder directly in a root, plus
    /// deeper folders that look like projects: they contain .git, package.json, Package.swift, pubspec.yaml,
    /// Cargo.toml, pyproject.toml, go.mod or CLAUDE.md.
    /// Does not descend into a project once found, nor into hidden folders, node_modules, .build, .next, dist, build,
    /// Pods, vendor, Library, packages (.app bundles and the like), or the privacy-protected folders directly in the
    /// home folder (Desktop, Documents and so on). Each root itself is included when it qualifies. Sorted by name, de-duplicated by path.
    /// Blocking: call it off the main thread.
    nonisolated static func scan(roots: [String], maxDepth: Int = 3) -> [ProjectEntry] {
        var found: [String: ProjectEntry] = [:]
        for root in roots {
            let path = (root.expandingTilde as NSString).standardizingPath
            visit(path, depth: 0, maxDepth: maxDepth, isRoot: true, found: &found)
        }
        return found.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }

    // A root is always walked even when it qualifies itself (~/development carries a CLAUDE.md, for example),
    // otherwise the projects inside it would never be listed.
    private static func visit(_ dir: String, depth: Int, maxDepth: Int, isRoot: Bool, found: inout [String: ProjectEntry]) {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: childKeys) else {
            return
        }
        let isProject = children.contains(where: { markers.contains($0.lastPathComponent) })
        // Every folder directly in a root is listed too, so work folders without code (proposals, research) show up.
        if isProject || depth == 1 {
            found[dir] = ProjectEntry(
                path: dir,
                name: dir.lastPathComponentOrSelf,
                detail: (dir as NSString).deletingLastPathComponent.abbreviatingHome
            )
        }
        if isProject && !isRoot { return }
        guard depth < maxDepth else { return }
        let isHome = dir == NSHomeDirectory()
        for child in children {
            let name = child.lastPathComponent
            guard !name.hasPrefix("."), !skippedFolders.contains(name),
                  !(isHome && protectedHomeFolders.contains(name)),
                  let values = try? child.resourceValues(forKeys: Set(childKeys)),
                  values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true
            else { continue }
            visit((dir as NSString).appendingPathComponent(name), depth: depth + 1, maxDepth: maxDepth, isRoot: false, found: &found)
        }
    }
}
