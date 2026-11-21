import Foundation
import ImageIO
import UniformTypeIdentifiers

// Owner: project icons builder (feature/older-section follow-on).

extension SmokeTest {
    /// Smoke check 19. Project icons: the lookup order in a project and one level down, a chosen image copied and
    /// downscaled next to the state file, an emoji, removal falling back to the project's own icon, and nothing
    /// written anywhere but the temp state folder.
    func checkProjectIcons(directory: String) async {
        var failures: [String] = []
        let icons = ProjectIcons.shared
        let fileManager = FileManager.default
        let stateFolder = Persistence.stateURL.deletingLastPathComponent().standardizedFileURL.path
        if icons.folder.standardizedFileURL.path != stateFolder
            || icons.mappingURL.deletingLastPathComponent().standardizedFileURL.path != stateFolder
            || icons.imagesFolder.deletingLastPathComponent().standardizedFileURL.path != stateFolder {
            failures.append("icons are stored at \(icons.folder.path), not in the state folder \(stateFolder)")
        }

        let project = (directory as NSString).appendingPathComponent("icons-project")
        let nested = (directory as NSString).appendingPathComponent("icons-nested")
        let bare = (directory as NSString).appendingPathComponent("icons-bare")
        func put(_ relative: String, in root: String, width: Int = 48, height: Int = 48) {
            let path = (root as NSString).appendingPathComponent(relative)
            try? fileManager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard let data = iconTestPNG(width: width, height: height) else { return failures.append("could not make a test PNG") }
            fileManager.createFile(atPath: path, contents: data)
        }
        func expectFound(_ root: String, _ relative: String?, _ step: String) {
            let found = ProjectIcons.findIcon(inProject: root)
            let expected = relative.map { (root as NSString).appendingPathComponent($0) }
            if found != expected { failures.append("\(step): found \(found ?? "nothing"), expected \(expected ?? "nothing")") }
        }

        // Lookup order: later candidates lose to earlier ones, the root beats a subfolder, site/ beats web/.
        try? fileManager.createDirectory(atPath: bare, withIntermediateDirectories: true)
        expectFound(bare, nil, "no icon")
        put("public/favicon.ico", in: project)
        expectFound(project, "public/favicon.ico", "favicon only")
        put("public/logo.png", in: project)
        expectFound(project, "public/logo.png", "logo over favicon")
        put("app/icon.png", in: project)
        expectFound(project, "app/icon.png", "app icon first")
        put("web/public/favicon.png", in: nested)
        expectFound(nested, "web/public/favicon.png", "one level down")
        put("site/app/favicon.ico", in: nested)
        expectFound(nested, "site/app/favicon.ico", "site before web")
        put("public/favicon.ico", in: nested)
        expectFound(nested, "public/favicon.ico", "root before subfolders")
        let home = NSHomeDirectory()
        for path in [home + "/Documents/app", home + "/Desktop", "/Volumes/Backup/app"] where !ProjectIcons.isProtected(path) {
            failures.append("\(path) is not treated as protected")
        }
        if ProjectIcons.isProtected(directory) || ProjectIcons.isProtected(home + "/development/app") {
            failures.append("an ordinary folder is treated as protected")
        }

        // The sidebar's lookup runs off the main thread and then shows the project's own icon.
        await icons.lookupFinished(forRoot: project)
        guard case .image(_, custom: false)? = icons.icon(forRoot: project) else {
            failures.append("no project icon after the lookup: \(String(describing: icons.icon(forRoot: project)))")
            return record("19 project icons", false, failures.joined(separator: "; "))
        }
        let projectFiles = Set(fileManager.enumerator(atPath: project)?.allObjects as? [String] ?? [])

        // A chosen image is copied, downscaled to 64 px on its longer side, and survives the original going away.
        let source = (directory as NSString).appendingPathComponent("icon-source.png")
        put("icon-source.png", in: directory, width: 300, height: 200)
        let chosen = await icons.setImage(from: URL(fileURLWithPath: source), forRoot: project)
        let copyName = icons.choice(forRoot: project)?.image
        let copy = copyName.map { icons.imagesFolder.appendingPathComponent($0) }
        let size = copy.flatMap(iconPixelSize)
        if !chosen || copy == nil || size?.width != 64 || !(42...43).contains(size?.height ?? 0) {
            failures.append("chosen image gave copy \(copy?.path ?? "none") at \(String(describing: size)), expected 64 by 43")
        }
        try? fileManager.removeItem(atPath: source)
        let reloaded = ProjectIcons(folder: icons.folder)
        guard case .image(_, custom: true)? = reloaded.icon(forRoot: project), reloaded.choice(forRoot: project)?.image == copyName else {
            failures.append("the custom image did not survive a reload without its original")
            return record("19 project icons", false, failures.joined(separator: "; "))
        }

        // An emoji replaces it and the copy goes. Text that is not an emoji changes nothing.
        if !icons.setEmoji("🥁", forRoot: project) { failures.append("the drum emoji was refused") }
        if case .emoji("🥁")? = icons.icon(forRoot: project) {} else {
            failures.append("emoji icon reads \(String(describing: icons.icon(forRoot: project)))")
        }
        if let copy, fileManager.fileExists(atPath: copy.path) { failures.append("the replaced image copy was left behind") }
        if icons.setEmoji("x", forRoot: project) || icons.choice(forRoot: project)?.emoji != "🥁" {
            failures.append("plain text was taken as an emoji")
        }
        if ProjectIcons.firstEmoji(in: "❤️ love") != "❤️" || ProjectIcons.firstEmoji(in: "7") != nil {
            failures.append("emoji detection: \(ProjectIcons.firstEmoji(in: "❤️ love") ?? "nil"), \(ProjectIcons.firstEmoji(in: "7") ?? "nil")")
        }
        if ProjectIcons(folder: icons.folder).choice(forRoot: project)?.emoji != "🥁" {
            failures.append("the emoji was not saved to project-icons.json")
        }

        // Removing it falls back to the project's own icon.
        icons.removeIcon(forRoot: project)
        if icons.choice(forRoot: project) != nil { failures.append("Remove Icon left a custom icon") }
        guard case .image(_, custom: false)? = icons.icon(forRoot: project) else {
            failures.append("after removal the icon reads \(String(describing: icons.icon(forRoot: project)))")
            return record("19 project icons", false, failures.joined(separator: "; "))
        }

        // Nothing was written into the project, and every copy made went into the state folder and is gone again.
        let projectFilesAfter = Set(fileManager.enumerator(atPath: project)?.allObjects as? [String] ?? [])
        if projectFilesAfter != projectFiles {
            failures.append("the project changed: \(projectFilesAfter.symmetricDifference(projectFiles).sorted())")
        }
        let leftover = (try? fileManager.contentsOfDirectory(atPath: icons.imagesFolder.path)) ?? []
        if !leftover.isEmpty { failures.append("copies left in project-icons: \(leftover)") }

        record("19 project icons", failures.isEmpty,
               failures.isEmpty ? "lookup order held (root, then site, web, app; protected folders skipped), a 300 by 200 "
                                    + "image was copied at 64 by 43 into the state folder and outlived its original, the "
                                    + "emoji replaced it, removal fell back to app/icon.png, the project was untouched"
                                : failures.joined(separator: "; "))
    }
}

/// A solid PNG of the given size.
private func iconTestPNG(width: Int, height: Int) -> Data? {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

private func iconPixelSize(_ url: URL) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (width, height)
}
