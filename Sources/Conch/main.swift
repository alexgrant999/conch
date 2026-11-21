import AppKit

// Owner: shell agent. AppDelegate handles launch, including --smoke-test.

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(ConchInfo.isIsolated ? .accessory : .regular)
    app.run()
}
