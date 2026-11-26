import AppKit

// Owner: model builder (feature/model).

extension AppDelegate {
    /// Adds a Model submenu to the menu passed in: a submenu per family (Latest, then each model, checked on the
    /// active session's), then Other Model….
    func addModelMenuItems(to menu: NSMenu) {
        let target = ModelMenuTarget.shared
        let submenu = NSMenu(title: "Model")
        for family in ClaudeModels.families {
            let familyMenu = NSMenu(title: family.name)
            for (index, choice) in ([family.latest] + family.versions).enumerated() {
                if index == 1 { familyMenu.addItem(.separator()) }
                let item = NSMenuItem(title: choice.name, action: #selector(ModelMenuTarget.choose(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = choice.model
                familyMenu.addItem(item)
            }
            let parent = NSMenuItem(title: family.name, action: nil, keyEquivalent: "")
            parent.submenu = familyMenu
            submenu.addItem(parent)
        }
        submenu.addItem(.separator())
        let other = NSMenuItem(title: "Other Model…", action: #selector(ModelMenuTarget.chooseOther(_:)), keyEquivalent: "")
        other.target = target
        submenu.addItem(other)
        let parent = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
    }
}

/// Menu items hold their target weakly, so it lives on as a singleton.
@MainActor
final class ModelMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = ModelMenuTarget()

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let session = ContextActions.actionableSession() else {
            menuItem.state = .off
            return false
        }
        if let choice = choice(of: menuItem) {
            menuItem.state = ModelActions.isCurrent(choice, for: session) ? .on : .off
        }
        return true
    }

    @objc func choose(_ sender: NSMenuItem) {
        guard let session = ContextActions.actionableSession(), let choice = choice(of: sender) else { return }
        ModelActions.choose(choice, for: session)
    }

    @objc func chooseOther(_ sender: Any?) {
        ContextActions.actionableSession().map(ModelActions.chooseOther)
    }

    private func choice(of item: NSMenuItem) -> ClaudeModelChoice? {
        guard let model = item.representedObject as? String else { return nil }
        return ClaudeModels.all.first { $0.model == model }
    }
}
