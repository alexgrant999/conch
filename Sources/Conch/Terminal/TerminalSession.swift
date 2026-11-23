import AppKit
import Combine
import SwiftTerm

// Owner: core agent. Public signatures are fixed by the contract.

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id: UUID
    private(set) var spec: LaunchSpec
    let view: ConchTerminalView

    /// User-chosen name. nil means "use the title or the default name".
    @Published var customName: String?
    /// Last OSC 0/2 title from the program, sanitized (control and bidi characters stripped, trimmed, max 120 chars).
    @Published private(set) var title: String = ""
    /// Live working directory of the shell (libproc, or OSC 7 when the shell sends it).
    @Published private(set) var currentDirectory: String
    @Published private(set) var activity: ActivityState = .starting
    @Published private(set) var attention: Attention = .none
    /// Name of the foreground process when it is not the shell itself, for example "claude", "node", "vim". nil when the shell is idle at its prompt.
    @Published private(set) var foregroundProcess: String?
    /// Context use reported by Claude Code (Claude sessions only). nil until the first report.
    @Published var context: ContextUsage?

    /// Fired when attention escalates to `.done` or `.needsInput` while not visible. The store routes it to Notifier.
    var onAttention: ((TerminalSession, Attention) -> Void)?
    /// Fired once when the child process exits.
    var onExit: ((TerminalSession, Int32?) -> Void)?
    /// Fired when this session's view becomes first responder (user clicked or tabbed into the pane).
    var onFocus: ((TerminalSession) -> Void)?
    /// Fired on typing, counted output and visibility changes. The store keeps last active times from it.
    var onUse: ((TerminalSession, SessionUse) -> Void)?

    /// Set by the store. True while the user can see this pane (app active, window visible, its group selected).
    /// Setting it to true clears attention.
    var isVisibleToUser: Bool = false {
        didSet {
            if isVisibleToUser { clearAttention() }
            if isVisibleToUser != oldValue { onUse?(self, .visibility) }
        }
    }

    private enum Phase {
        case notStarted, running, exited, terminated
    }

    /// A busy streak at least this long that ends while hidden marks the session done.
    private static let doneStreak: TimeInterval = 4
    private static let evaluationInterval: TimeInterval = 0.25
    /// Grace period between SIGHUP/SIGTERM and SIGKILL in `terminate()`.
    private static let killDelay: TimeInterval = 2
    private static let scrollbackLines = 5_000
    private static let shellName = LaunchCommand.userShell().lastPathComponentOrSelf

    private let restoring: Bool
    private let tracker = ActivityTracker()
    private var phase = Phase.notStarted
    private var evaluationTimer: Timer?
    private var oscObservation: TerminalOscObservation?
    private var kittyNotification = KittyNotificationAssembler()
    private var busyStreak: TimeInterval = 0
    private var appliedFontSize: CGFloat?

    /// - Parameters:
    ///   - startDirectory: where a restored `.shell` starts (its last live cwd). Defaults to `spec.cwd`.
    ///   - restoring: true when recreated from saved state on launch. Changes the Claude command (resume instead of new).
    init(id: UUID = UUID(),
         spec: LaunchSpec,
         customName: String? = nil,
         lastTitle: String? = nil,
         startDirectory: String? = nil,
         restoring: Bool = false) {
        self.id = id
        self.spec = spec
        self.customName = customName
        self.title = TerminalText.sanitizeTitle(lastTitle ?? "")
        self.currentDirectory = startDirectory ?? spec.cwd
        self.restoring = restoring
        self.view = ConchTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))

        view.changeScrollback(Self.scrollbackLines)
        // Option+Return, Option+Backspace and Option+arrows stay Meta even when Option-as-Meta is off for text.
        view.optionAsMetaKeyForFunctionalKeys = true
        view.activityTracker = tracker
        view.cleansCopiedText = spec.kind != .shell
        view.processDelegate = self
        view.setProcessOutputHandler { [tracker] in tracker.noteOutput() }
        view.onBell = { [weak self] in self?.raiseAttention(.needsInput(message: nil), notify: true) }
        view.onBecameFirstResponder = { [weak self] in
            guard let self else { return }
            self.onFocus?(self)
        }
        view.onUserInput = { [weak self] in
            guard let self else { return }
            self.onUse?(self, .input)
        }
        applyAppearance(fontSize: 13, optionAsMeta: true)
    }

    /// customName, else the sanitized title, else `defaultName`.
    var displayName: String { customName ?? (title.isEmpty ? defaultName : title) }

    /// "Claude", "Web session", or the shell name ("zsh").
    var defaultName: String {
        switch spec.kind {
        case .shell: return Self.shellName
        case .claude: return "Claude"
        case .cloud: return "Web session"
        }
    }

    /// True when a process other than the shell owns the terminal's foreground process group.
    var hasRunningChild: Bool {
        guard phase == .running, let process = view.process else { return false }
        let shellPid = process.shellPid
        guard shellPid > 0, let group = ProcessInspector.foregroundProcessGroup(ptyFD: process.childfd) else {
            return false
        }
        return group != shellPid
    }

    /// Spawns the process. Idempotent: a second call does nothing.
    func start() {
        guard phase == .notStarted else { return }
        phase = .running

        oscObservation = view.observeOscEvents { [weak self] event in
            guard event.code == 9 || event.code == 99 || event.code == 777 else { return }
            // Main queue, not a Task: OSC 99 chunks must stay in order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleNotification(event) }
            }
        }

        let plan = LaunchCommand.plan(for: spec,
                                      sessionID: id,
                                      displayName: remoteControlName,
                                      startDirectory: currentDirectory,
                                      restoring: restoring)
        if let banner = plan.banner {
            view.feed(text: banner)
        }
        view.startProcess(executable: plan.executable,
                          args: plan.args,
                          environment: plan.environment,
                          currentDirectory: plan.currentDirectory)
        // The pty master is created inheritable, so every session spawned later would hold this one open (and be
        // able to read and type into it). All spawns happen on main, so this lands before the next one.
        if let fd = view.process?.childfd, fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        setCurrentDirectory(plan.currentDirectory)
        setActivity(.idle)
        startEvaluationTimer()
    }

    /// Changes the spec after launch: a startup command set later, or the conversation id after /clear. Takes
    /// effect on the next launch or restore. The caller schedules a save.
    func updateSpec(_ change: (inout LaunchSpec) -> Void) {
        change(&spec)
    }

    /// Hangs up the process group and terminates the child. Safe to call twice.
    func terminate() {
        guard phase != .terminated else { return }
        let wasRunning = phase == .running
        phase = .terminated
        stopEvaluationTimer()
        oscObservation?.cancel()
        oscObservation = nil
        view.setProcessOutputHandler(nil)

        if wasRunning, let process = view.process {
            let shellPid = process.shellPid
            if shellPid > 0 {
                // SIGHUP is what a closing terminal sends. Claude Code and shells exit cleanly on it, and the shell
                // passes it on to its jobs. LocalProcess.terminate() only sends SIGTERM to the shell, which
                // interactive shells ignore, and never escalates while the view is alive.
                var job: pid_t?
                if let group = ProcessInspector.foregroundProcessGroup(ptyFD: process.childfd), group != shellPid {
                    job = group
                }
                let groups = (job: job, shell: shellPid)
                hungUpGroups = groups
                if let job {
                    killpg(job, SIGHUP)
                    // Servers such as gunicorn, postgres and nginx reload on SIGHUP instead of exiting.
                    killpg(job, SIGTERM)
                }
                killpg(shellPid, SIGHUP)
                process.terminate()
                // The shell usually exits on SIGHUP before the deadline, so the kill must not depend on it being
                // alive. Capturing self keeps the LocalProcess and its reaper alive until then.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.killDelay) {
                    MainActor.assumeIsolated {
                        _ = self
                        Self.killSurvivors(groups)
                    }
                }
            } else {
                process.terminate()
            }
        }
        view.closeUI()
    }

    /// Writes text to the pty as if typed.
    func send(text: String) {
        view.sendAsUser(text)
    }

    /// Re-reads cwd and foreground process via libproc. The store calls this on a ~2 s timer and before saving.
    func refreshProcessInfo() {
        guard phase == .running, let process = view.process else { return }
        let shellPid = process.shellPid
        guard shellPid > 0 else { return }
        // libproc reports the physical path. Keep the current value (spec.cwd or an OSC 7 path, as the user typed
        // it) while it names the same directory, else take libproc's in Foundation's form (/tmp, not /private/tmp).
        if let physical = ProcessInspector.currentDirectory(of: shellPid),
           ProcessInspector.physicalPath(currentDirectory) != physical {
            setCurrentDirectory(URL(fileURLWithPath: physical).resolvingSymlinksInPath().path)
        }
        updateForegroundProcess()
    }

    func clearAttention() {
        if attention != .none { attention = .none }
    }

    /// Makes the terminal view first responder in its window.
    func focus() {
        guard let window = view.window, window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
    }

    func clearScrollback() {
        view.clearScrollback()
    }

    /// Applies font size, colors for the current light/dark appearance, and the Option-as-Meta preference.
    func applyAppearance(fontSize: CGFloat, optionAsMeta: Bool) {
        // Setting the font re-measures cells and drops the selection, so skip it when nothing changed.
        if appliedFontSize != fontSize {
            appliedFontSize = fontSize
            view.font = TerminalTheme.font(size: fontSize)
        }
        view.optionAsMetaKey = optionAsMeta
        TerminalTheme.apply(to: view, dark: TerminalTheme.isDark(view.effectiveAppearance))
        // The program redraws after a resize or color change. That is not activity.
        tracker.noteInput()
    }

    /// Plain text of the visible screen plus scrollback. Used by the smoke test.
    func bufferText() -> String {
        String(decoding: view.getBufferAsData(), as: UTF8.self)
    }

    func persisted() -> PersistedSession {
        PersistedSession(id: id,
                         customName: customName,
                         lastTitle: title.isEmpty ? nil : title,
                         lastDirectory: currentDirectory,
                         spec: spec)
    }

    // MARK: - Private

    /// Name passed to `--remote-control`. A fresh session has no title yet, and a list of sessions all called
    /// "Claude" in claude.ai/code is useless, so it falls back to the folder name.
    private var remoteControlName: String {
        if let customName, !customName.isEmpty { return customName }
        return title.isEmpty ? spec.cwd.lastPathComponentOrSelf : title
    }

    private func setActivity(_ next: ActivityState) {
        if activity != next { activity = next }
    }

    private func setCurrentDirectory(_ path: String) {
        if currentDirectory != path { currentDirectory = path }
    }

    /// Attention only escalates by rank until cleared. A message-less needsInput (bell) can gain a message from a
    /// following OSC notification.
    private func raiseAttention(_ next: Attention, notify: Bool) {
        guard !isVisibleToUser else { return }
        var addsMessage = false
        if case .needsInput(.none) = attention, case .needsInput(.some) = next {
            addsMessage = true
        }
        guard next.rank > attention.rank || addsMessage else { return }
        attention = next
        if notify { onAttention?(self, next) }
    }

    private func handleNotification(_ event: TerminalOscEvent) {
        let notification = event.code == 99
            ? kittyNotification.consume(event.payload)
            : TerminalText.notification(code: event.code, payload: event.payload)
        guard let notification else { return }
        raiseAttention(.needsInput(message: notification.message), notify: true)
    }

    private func startEvaluationTimer() {
        // Every session's timer fires on one shared grid, so idle sessions opened at different times wake together
        // instead of each adding its own wakeups.
        let interval = Self.evaluationInterval
        let firstFire = Date(timeIntervalSinceReferenceDate:
            (Date.timeIntervalSinceReferenceDate / interval).rounded(.up) * interval)
        let timer = Timer(fire: firstFire, interval: interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.evaluateActivity()
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        evaluationTimer = timer
    }

    private func stopEvaluationTimer() {
        evaluationTimer?.invalidate()
        evaluationTimer = nil
    }

    private func evaluateActivity() {
        guard phase == .running else { return }
        let reading = tracker.read()
        if reading.busy {
            busyStreak = reading.streakLength
            setActivity(.busy)
        } else {
            if activity == .busy, max(busyStreak, reading.streakLength) >= Self.doneStreak {
                raiseAttention(.done, notify: true)
            }
            busyStreak = 0
            setActivity(.idle)
        }
        if reading.countedOutput {
            raiseAttention(.unread, notify: false)
            onUse?(self, .output)
        }
        updateForegroundProcess()
    }

    /// One tcgetpgrp per call, plus proc_name while a job runs: the name can change after the group appears,
    /// because the forked shell child only becomes "sleep" once it execs.
    private func updateForegroundProcess() {
        guard let process = view.process else { return }
        let shellPid = process.shellPid
        let group = shellPid > 0 ? ProcessInspector.foregroundProcessGroup(ptyFD: process.childfd) : nil
        var name: String?
        if let group, group != shellPid {
            name = ProcessInspector.processName(of: group)
        }
        if foregroundProcess != name { foregroundProcess = name }
    }

    private func handleExit(code: Int32?) {
        stopEvaluationTimer()
        setActivity(.exited(code: code))
        if foregroundProcess != nil { foregroundProcess = nil }
        guard phase == .running else { return }
        phase = .exited
        onExit?(self, code)
    }

    /// Process groups `terminate()` hung up: the foreground job when it is not the shell, and the shell's own
    /// group (the shell leads its session). `SessionStore.terminateAll` uses them to finish the job on quit.
    private(set) var hungUpGroups: (job: pid_t?, shell: pid_t)?

    /// SIGKILL to each group that still has a live member.
    nonisolated static func killSurvivors(_ groups: (job: pid_t?, shell: pid_t)) {
        for group in [groups.job, groups.shell].compactMap({ $0 }) where killpg(group, 0) == 0 {
            killpg(group, SIGKILL)
        }
    }
}

extension TerminalSession: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // The program repaints after SIGWINCH, including hidden panes when the window resizes.
        tracker.noteInput()
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let clean = TerminalText.sanitizeTitle(title)
        if clean != self.title { self.title = clean }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let path = TerminalText.directory(fromOSC7: directory) {
            setCurrentDirectory(path)
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        handleExit(code: exitCode)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        handleExit(code: nil)
    }
}
