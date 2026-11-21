import AppKit
import SwiftTerm

// Owner: core agent.

/// SwiftTerm view with the hooks Conch needs.
/// - Shift+Return sends ESC CR (Claude Code reads it as "insert newline").
/// - Bell is surfaced through `onBell` (LocalProcessTerminalView does not forward it to processDelegate).
/// - Becoming first responder is surfaced through `onBecameFirstResponder` so the store can track the focused pane.
///
/// SwiftTerm 1.99.3 declares `keyDown`, `performKeyEquivalent`, `becomeFirstResponder` and `send(data:)` as
/// public, not open, so they cannot be overridden here. Instead:
/// - Keys go through one app-wide local key monitor (Shift+Return and input timestamps).
/// - Focus comes from the open `hasFocus` setter, which `becomeFirstResponder` calls.
/// - LocalProcessTerminalView routes typed text and pastes straight to the pty, bypassing
///   `send(source:data:)`. That override only sees mouse reports, focus reports and query replies.
final class ConchTerminalView: LocalProcessTerminalView {
    var onBell: (() -> Void)?
    var onBecameFirstResponder: (() -> Void)?
    /// Keys typed into the view, pastes, and text sent as if typed. Not mouse reports or query replies.
    var onUserInput: (() -> Void)?

    /// Receives user input timestamps for echo filtering. Set by TerminalSession.
    var activityTracker: ActivityTracker?

    private var isResponder = false
    private var isClosed = false

    private static var keyMonitor: Any?
    private static let returnKeyCode: UInt16 = 36
    /// CoreGraphics is the default. `CONCH_METAL=1` opts into SwiftTerm's Metal renderer, falling back silently.
    private static let metalRequested = ProcessInfo.processInfo.environment["CONCH_METAL"] == "1"

    override var hasFocus: Bool {
        get { super.hasFocus }
        set {
            let became = newValue && !isResponder
            isResponder = newValue
            super.hasFocus = newValue
            // Deferred so a handler that moves focus does not re-enter makeFirstResponder.
            if became {
                Task { @MainActor [weak self] in self?.onBecameFirstResponder?() }
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !isClosed else { return }
        Self.installKeyMonitorIfNeeded()
        if Self.metalRequested, !isUsingMetalRenderer {
            try? setUseMetal(true)
        }
    }

    /// Runs on the IO parse thread. Super queues the audible or visual bell.
    nonisolated override func bell(source: Terminal) {
        super.bell(source: source)
        Task { @MainActor [weak self] in self?.onBell?() }
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        activityTracker?.noteInput()
        super.send(source: source, data: data)
    }

    override func paste(_ sender: Any) {
        activityTracker?.noteInput()
        onUserInput?()
        super.paste(sender)
    }

    /// Writes text to the pty as if typed.
    func sendAsUser(_ text: String) {
        activityTracker?.noteInput()
        onUserInput?()
        send(txt: text)
    }

    /// Permanent teardown (SwiftTerm requires `updateUiClosed` from the owner). Retries while Metal work is in flight.
    func closeUI() {
        guard !isClosed else { return }
        isClosed = true
        attemptUIClose(retriesLeft: 50)
    }

    private func attemptUIClose(retriesLeft: Int) {
        guard !updateUiClosed(), retriesLeft > 0 else { return }
        // Holds the view until the GPU lets go, as SwiftTerm's own sample does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated { self.attemptUIClose(retriesLeft: retriesLeft - 1) }
        }
    }

    private static func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { handleKeyDown(event) }
            return consumed ? nil : event
        }
    }

    /// Returns true when the event was handled here and must not reach the view.
    private static func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let view = event.window?.firstResponder as? ConchTerminalView, !view.isClosed else { return false }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        // Command keys belong to the menus.
        guard !modifiers.contains(.command) else { return false }
        view.activityTracker?.noteInput()
        view.onUserInput?()
        guard event.keyCode == returnKeyCode, modifiers == .shift, !view.hasMarkedText() else { return false }
        view.send([0x1B, 0x0D])
        return true
    }
}
