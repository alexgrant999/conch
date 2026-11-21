import AppKit

/// A short message over the bottom of the main window that fades on its own, for a shortcut that had nothing to act
/// on. A beep alone is easy to miss, and silent when alert sounds are off. It is a child window rather than a subview
/// so terminal views added while it shows cannot cover it, and it ignores the mouse.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    /// The message on screen, nil once it has faded. Read by the smoke test.
    private(set) static var currentMessage: String?

    private static let visibleFor: TimeInterval = 1.8
    private static let padding = NSSize(width: 16, height: 9)

    /// Beeps instead when the main window is not on screen, since there is nothing to show it over.
    static func show(_ message: String) {
        guard let window = AppActions.mainWindow, window.isVisible, !window.isMiniaturized else {
            NSSound.beep()
            return
        }
        dismiss()

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        let text = label.fittingSize
        let size = NSSize(width: min(text.width + padding.width * 2, window.frame.width - 40),
                          height: text.height + padding.height * 2)
        label.frame = NSRect(x: padding.width, y: padding.height, width: size.width - padding.width * 2, height: text.height)

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        background.addSubview(label)

        let toast = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.hasShadow = true
        toast.ignoresMouseEvents = true
        toast.isReleasedWhenClosed = false
        toast.appearance = window.effectiveAppearance
        toast.contentView = background
        toast.setFrameOrigin(NSPoint(x: window.frame.midX - size.width / 2, y: window.frame.minY + 32))
        window.addChildWindow(toast, ordered: .above)
        panel = toast
        currentMessage = message
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])

        DispatchQueue.main.asyncAfter(deadline: .now() + visibleFor) { [weak toast] in
            MainActor.assumeIsolated {
                guard let toast, toast === panel else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    toast.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated {
                        if toast === panel { dismiss() }
                    }
                })
            }
        }
    }

    static func dismiss() {
        guard let toast = panel else { return }
        toast.parent?.removeChildWindow(toast)
        toast.orderOut(nil)
        panel = nil
        currentMessage = nil
    }
}
