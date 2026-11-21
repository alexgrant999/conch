import AppKit

// Owner: modules builder (feature/modules-section).

extension AppDelegate {
    /// Adds this feature's items to the menu passed in. Give each item its own target object (in this file)
    /// with a validateMenuItem, so AppDelegate.swift needs no changes.
    func addModulesMenuItems(to menu: NSMenu) {
        menu.addItem(.separator())
        // An uppercase key implies Shift: ⇧⌘M.
        let modules = item("Modules", #selector(ModulesMenuTarget.showModules(_:)), "M")
        modules.target = ModulesMenuTarget.shared
        menu.addItem(modules)
    }
}

/// Menu items hold their target weakly, so this lives for the whole run.
@MainActor
final class ModulesMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = ModulesMenuTarget()

    @objc func showModules(_ sender: Any?) {
        ModulesWindowController.shared.present()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        NSApp.modalWindow == nil
    }
}
