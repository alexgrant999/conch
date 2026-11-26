import AppKit
import Combine

/// One tab. Holds one or more sessions shown side by side (a split).
@MainActor
final class SessionGroup: ObservableObject, Identifiable {
    let id: UUID
    @Published var sessions: [TerminalSession]
    @Published var focusedSessionID: UUID?

    init(id: UUID = UUID(), sessions: [TerminalSession], focusedSessionID: UUID? = nil) {
        self.id = id
        self.sessions = sessions
        self.focusedSessionID = focusedSessionID ?? sessions.first?.id
    }

    var focusedSession: TerminalSession? {
        sessions.first { $0.id == focusedSessionID } ?? sessions.first
    }
}

/// Sidebar section: groups whose first session's `spec.cwd` resolves to the same project root
/// (nearest ancestor containing .git, else the cwd itself). Ordered by first appearance in `groups`.
struct ProjectSection: Identifiable {
    /// Project root path.
    let id: String
    /// Folder name of the root, "~" for the home directory.
    let name: String
    let groups: [SessionGroup]
}

/// `groups` is kept in sidebar order: the project sections, then the Older section. Groups that share a project root
/// are contiguous within each part, so the sidebar's visual order, `groups` order and `allSessions` order are the same
/// thing (Cmd+1...9, Ctrl+Tab, Cmd+J ties and neighbour selection on close all follow what the user sees).
/// `projectOrder` keeps every group's place in its project, so a group leaving Older lands where it was.
@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore(settings: .shared)

    let settings: AppSettings

    /// Sidebar order. Each group is one tab.
    @Published private(set) var groups: [SessionGroup] = []
    @Published var selectedGroupID: UUID? {
        didSet {
            if let id = selectedGroupID, !groups.contains(where: { $0.id == id }) {
                selectedGroupID = groups.first?.id
            }
            guard selectedGroupID != oldValue else { return }
            noteSelectionChanged(from: oldValue)
            recomputeVisibility()
            scheduleSave()
        }
    }
    /// Session whose sidebar row is in inline-rename mode. The sidebar sets it back to nil on commit or cancel.
    @Published var renamingSessionID: UUID?

    /// `attentionCount` for the menu bar item. A subject rather than @Published so a count change does not
    /// re-render every view observing the store.
    let waitingCountPublisher = CurrentValueSubject<Int, Never>(0)

    private var projectRootCache: [String: String] = [:]
    private var attentionObservers: [UUID: AnyCancellable] = [:]
    /// When each waiting session's attention reached its current rank. Orders `waitingSessions`.
    private var attentionRaised: [UUID: (rank: Int, at: Date)] = [:]
    private var lastJumpTargetID: UUID?
    private var cancellables: Set<AnyCancellable> = []
    private var saveTask: Task<Void, Never>?
    private var isTerminating = false
    /// Claude and web sessions whose folder was missing at launch (a drive not mounted yet, a folder mid-rename).
    /// Saved back unchanged so the next launch can try again instead of losing them.
    private var unrestoredGroups: [PersistedGroup] = []
    private var appliedAppearance: (fontSize: Double, optionAsMeta: Bool)?
    /// Restored sessions replay their start-up output while hidden. Their attention from that window is noise.
    private var restoreQuietSessionIDs: Set<UUID> = []
    /// Every group in project order, Older ones included at the places they had. `groups` is this with the Older
    /// groups moved to the end.
    private var projectOrder: [SessionGroup] = []
    /// Groups in the Older section: every session idle longer than `settings.olderAfterHours`.
    private var olderGroupIDs: Set<UUID> = []
    /// Last typing, counted output or visibility change per session. Wall clock, so it survives a relaunch.
    private var lastActiveTimes: [UUID: Date] = [:]
    private var olderCheck: DispatchWorkItem?
    /// When the next group crosses the Older threshold. nil when none will (the setting is off, or every group other
    /// than the selected one is in Older already).
    private(set) var nextOlderCheck: Date?
    /// The clock for last active times. The smoke test moves it forward instead of waiting hours.
    var now: () -> Date = { Date() }

    private static let saveDelay: Duration = .seconds(1)
    private static let restoreQuietPeriod: Duration = .seconds(10)

    init(settings: AppSettings) {
        self.settings = settings

        let center = NotificationCenter.default
        let visibilityEvents: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ]
        Publishers.MergeMany(visibilityEvents.map { center.publisher(for: $0) })
            .sink { [weak self] _ in self?.recomputeVisibility() }
            .store(in: &cancellables)

        Timer.publish(every: 2, tolerance: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshTick() }
            .store(in: &cancellables)

        // Settings changes apply live. Deferred so the new values are set (@Published emits in willSet), and skipped
        // when a caller already applied them through applyAppearanceToAll().
        settings.$fontSize.combineLatest(settings.$optionAsMeta)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyAppearanceIfSettingsChanged() }
            .store(in: &cancellables)

        settings.$olderAfterHours
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshOlder() }
            .store(in: &cancellables)
    }

    var selectedGroup: SessionGroup? { groups.first { $0.id == selectedGroupID } }

    /// Focused session of the selected group.
    var activeSession: TerminalSession? { selectedGroup?.focusedSession }

    /// All sessions in sidebar order.
    var allSessions: [TerminalSession] { groups.flatMap(\.sessions) }

    /// The project sections, above the Older section. Groups in Older are not in them.
    var sections: [ProjectSection] {
        groupedByRoot(groups.filter { !olderGroupIDs.contains($0.id) })
            .map { ProjectSection(id: $0.root, name: Self.sectionName(forRoot: $0.root), groups: $0.groups) }
    }

    /// The Older section at the bottom of the session list, in project order. Empty when the setting is off.
    var olderGroups: [SessionGroup] { groups.filter { olderGroupIDs.contains($0.id) } }

    /// The project a group belongs to, as its section header names it. Also for a group shown in Older.
    func project(of group: SessionGroup) -> (root: String, name: String) {
        let root = projectRoot(of: group)
        return (root, Self.sectionName(forRoot: root))
    }

    /// Number of sessions whose attention is `.done` or `.needsInput`. Drives the dock badge.
    var attentionCount: Int {
        allSessions.reduce(0) { $0 + ($1.attention.rank >= Attention.done.rank ? 1 : 0) }
    }

    /// The sessions `attentionCount` counts, in jump order: `.needsInput` before `.done`, oldest raised first within
    /// each, sidebar order on ties.
    var waitingSessions: [TerminalSession] {
        let raisedAt: (TerminalSession) -> Date = { session in
            guard let raised = self.attentionRaised[session.id], raised.rank == session.attention.rank else {
                // Not recorded yet (the observer runs a turn later), so it is the newest.
                return .distantFuture
            }
            return raised.at
        }
        return allSessions.enumerated()
            .filter { $0.element.attention.rank >= Attention.done.rank }
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element, rhs.element)
                if left.attention.rank != right.attention.rank { return left.attention.rank > right.attention.rank }
                let (leftDate, rightDate) = (raisedAt(left), raisedAt(right))
                if leftDate != rightDate { return leftDate < rightDate }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Selects the next of `waitingSessions` and returns it. nil when nothing is waiting.
    /// Showing a session clears its attention, which moves the next call on. Until it shows (window hidden, or the
    /// app not active yet), a repeat call moves past the session the previous call selected instead.
    @discardableResult
    func selectNextWaiting() -> TerminalSession? {
        let waiting = waitingSessions
        guard var next = waiting.first else { return nil }
        if let last = lastJumpTargetID, last == activeSession?.id, let index = waiting.firstIndex(where: { $0.id == last }) {
            next = waiting[(index + 1) % waiting.count]
        }
        lastJumpTargetID = next.id
        select(next)
        return next
    }

    func session(withID id: UUID) -> TerminalSession? { allSessions.first { $0.id == id } }

    func group(containing session: TerminalSession) -> SessionGroup? {
        groups.first { $0.sessions.contains { $0 === session } }
    }

    // MARK: Creating sessions

    /// Creates, wires (onAttention, onExit, onFocus, appearance), registers and starts a session.
    /// - splitInto: id of an existing group to add it to (split pane to the right). nil makes a new group placed
    ///   right after the selected group.
    /// - select: select its group and focus it.
    /// Records `spec.cwd` in settings.recentDirectories.
    @discardableResult
    func newSession(_ spec: LaunchSpec, customName: String? = nil, splitInto groupID: UUID? = nil, select: Bool = true) -> TerminalSession {
        let session = TerminalSession(spec: spec, customName: customName)
        wire(session)

        if let groupID, let group = groups.first(where: { $0.id == groupID }) {
            group.sessions.append(session)
        } else {
            projectOrder.insert(SessionGroup(sessions: [session]), at: insertionIndex(forRoot: projectRoot(for: spec.cwd)))
        }
        projectOrder = sectionOrdered(projectOrder)
        // Republishes even for a split, so $groups subscribers see the new pane.
        arrangeGroups(republish: true)

        settings.noteRecentDirectory(spec.cwd)
        session.start()
        if select {
            self.select(session)
        }
        // A split into the already selected group does not change the selection, so recompute here as well.
        recomputeVisibility()
        scheduleSave()
        return session
    }

    /// Shell in `dir`, or `defaultDirectory()` when nil. `split` adds it to the selected group.
    @discardableResult
    func newShell(in dir: String? = nil, split: Bool = false) -> TerminalSession {
        newSession(.shell(resolvedDirectory(dir)), splitInto: split ? selectedGroupID : nil)
    }

    /// Claude session with Remote Control and model from the settings (see `newClaudeSpec`).
    @discardableResult
    func newClaude(in dir: String? = nil, split: Bool = false) -> TerminalSession {
        newSession(newClaudeSpec(in: resolvedDirectory(dir)), splitInto: split ? selectedGroupID : nil)
    }

    /// Resumes an existing Claude Code conversation (`claude --resume <id>`) in `dir`, the directory it ran in.
    /// Switches to it instead when a session here already runs that conversation.
    @discardableResult
    func resumeClaude(sessionID: UUID, in dir: String?) -> TerminalSession {
        if let existing = allSessions.first(where: { $0.spec.claude?.sessionID == sessionID && $0.spec.kind == .claude }) {
            select(existing)
            return existing
        }
        var spec = LaunchSpec.claude(resolvedDirectory(dir), remoteControl: settings.remoteControlByDefault)
        spec.claude?.sessionID = sessionID
        return newSession(spec)
    }

    /// `claude --cloud <target>` session. Target is a task description or a web session id or URL.
    @discardableResult
    func newCloud(target: String, in dir: String? = nil) -> TerminalSession {
        newSession(.cloud(resolvedDirectory(dir), target: target.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    // MARK: Closing, selection, order

    /// Terminates and removes the session. Removes its group when empty and picks a neighbouring selection.
    /// No confirmation here, the UI layer confirms first.
    func close(_ session: TerminalSession) {
        attentionObservers.removeValue(forKey: session.id)?.cancel()
        attentionRaised.removeValue(forKey: session.id)
        restoreQuietSessionIDs.remove(session.id)
        lastActiveTimes.removeValue(forKey: session.id)
        session.onAttention = nil
        session.onExit = nil
        session.onFocus = nil
        session.onUse = nil
        session.terminate()
        Notifier.shared.clear(sessionID: session.id)
        if renamingSessionID == session.id { renamingSessionID = nil }

        defer {
            Notifier.shared.updateDockBadge(count: attentionCount)
            publishWaitingCount()
            scheduleSave()
        }

        guard let groupIndex = groups.firstIndex(where: { $0.sessions.contains { $0 === session } }) else { return }
        let group = groups[groupIndex]
        guard let paneIndex = group.sessions.firstIndex(where: { $0 === session }) else { return }
        let wasSelected = group.id == selectedGroupID

        group.sessions.remove(at: paneIndex)

        if group.sessions.isEmpty {
            var remaining = groups
            remaining.remove(at: groupIndex)
            // Move the selection first, while the old group is still listed, so every intermediate state is valid.
            // The selected group is never in Older, so its neighbours come from the project sections while any
            // are left, rather than pulling the first Older group back up.
            if wasSelected {
                let recent = remaining.filter { !olderGroupIDs.contains($0.id) }
                let candidates = recent.isEmpty ? remaining : recent
                selectedGroupID = candidates.isEmpty ? nil : candidates[min(groupIndex, candidates.count - 1)].id
            }
            projectOrder.removeAll { $0 === group }
            olderGroupIDs.remove(group.id)
        } else {
            if !group.sessions.contains(where: { $0.id == group.focusedSessionID }) {
                group.focusedSessionID = group.sessions[max(paneIndex - 1, 0)].id
            }
            // The first pane can change, and with it the group's project root.
            projectOrder = sectionOrdered(projectOrder)
        }
        // The pane that kept the group recent may be the one that went.
        arrangeGroups(republish: true)

        recomputeVisibility()
        if wasSelected, let active = activeSession {
            focusWhenAttached(active)
        }
    }

    /// Selects the session's group, marks it focused and focuses its view.
    func select(_ session: TerminalSession) {
        guard let group = group(containing: session) else { return }
        markFocused(session, in: group)
        selectedGroupID = group.id
        focusWhenAttached(session)
    }

    /// Selects the group at a 0-based sidebar index (Cmd+1...9). Out of range does nothing.
    func selectGroup(at index: Int) {
        guard groups.indices.contains(index), let session = groups[index].focusedSession else { return }
        select(session)
    }

    /// Moves selection through sessions in sidebar order by delta, wrapping.
    func selectAdjacentSession(_ delta: Int) {
        let sessions = allSessions
        guard !sessions.isEmpty else { return }
        let current = activeSession.flatMap { active in sessions.firstIndex { $0 === active } }
        let start = current ?? (delta >= 0 ? -1 : sessions.count)
        select(sessions[Self.wrap(start + delta, count: sessions.count)])
    }

    /// Moves focus between panes of the selected group by delta, wrapping.
    func focusAdjacentPane(_ delta: Int) {
        guard let group = selectedGroup, group.sessions.count > 1 else { return }
        let current = group.sessions.firstIndex { $0.id == group.focusedSession?.id } ?? 0
        select(group.sessions[Self.wrap(current + delta, count: group.sessions.count)])
    }

    /// Reorders groups. `index` is the destination index in `groups` after removal.
    /// Groups stay contiguous by project, so moving a group into another project's block snaps it back to its own.
    /// The group goes after the one it follows on screen, so groups in Older keep their places in their projects.
    func moveGroup(_ id: UUID, to index: Int) {
        guard let from = groups.firstIndex(where: { $0.id == id }) else { return }
        var visual = groups
        let group = visual.remove(at: from)
        let destination = min(max(index, 0), visual.count)
        var list = projectOrder.filter { $0 !== group }
        let anchor = destination == 0 ? 0 : list.firstIndex { $0 === visual[destination - 1] }.map { $0 + 1 }
        list.insert(group, at: anchor ?? list.count)
        let ordered = sectionOrdered(list)
        guard ordered.map(\.id) != projectOrder.map(\.id) else { return }
        projectOrder = ordered
        arrangeGroups(republish: true)
        scheduleSave()
    }

    /// nil or empty clears the custom name.
    func rename(_ session: TerminalSession, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newName = trimmed.isEmpty ? nil : trimmed
        guard session.customName != newName else { return }
        objectWillChange.send()
        session.customName = newName
        scheduleSave()
    }

    // MARK: Environment

    /// Live cwd of the active session, else settings.defaultDirectory, else the home directory.
    func defaultDirectory() -> String {
        if let cwd = activeSession?.currentDirectory, Self.isDirectory(cwd) {
            return cwd
        }
        let preferred = (settings.defaultDirectory.expandingTilde as NSString).standardizingPath
        if Self.isDirectory(preferred) {
            return preferred
        }
        return NSHomeDirectory()
    }

    /// Re-applies font size and Option-as-Meta from settings to every session.
    func applyAppearanceToAll() {
        appliedAppearance = (settings.fontSize, settings.optionAsMeta)
        for session in allSessions {
            applyAppearance(to: session)
        }
    }

    /// Recomputes `isVisibleToUser` for every session from app active state, main window visibility and selection.
    /// The store also calls this itself on selection changes and app activation notifications.
    func recomputeVisibility() {
        let appActive = NSApplication.shared.isActive
        let mainWindow = AppActions.mainWindow
        for group in groups {
            let groupShown = appActive && group.id == selectedGroupID
            for session in group.sessions {
                let visible = groupShown && Self.isShowing(mainWindow ?? session.view.window)
                if session.isVisibleToUser != visible {
                    session.isVisibleToUser = visible
                }
            }
        }
    }

    // MARK: Persistence

    /// Writes PersistedState via Persistence. Refreshes process info first.
    func save() {
        saveTask?.cancel()
        saveTask = nil
        for session in allSessions where !session.activity.isExited {
            session.refreshProcessInfo()
        }
        let time = now()
        // Project order, not sidebar order, so a group in Older keeps its place in its project across a relaunch.
        let state = PersistedState(
            groups: projectOrder.map { group in
                let sessions = group.sessions.map { session in
                    var saved = session.persisted()
                    saved.lastActive = lastActive(of: session, at: time)
                    return saved
                }
                return PersistedGroup(id: group.id, sessions: sessions, focusedSessionID: group.focusedSession?.id)
            } + unrestoredGroups,
            selectedGroupID: selectedGroup?.id
        )
        Persistence.save(state)
    }

    /// Recreates sessions from Persistence with `restoring: true` when settings.restoreSessionsOnLaunch is on.
    /// Returns true when at least one session was restored.
    @discardableResult
    func restore() -> Bool {
        guard settings.restoreSessionsOnLaunch, let state = Persistence.load() else { return false }

        var knownGroupIDs = Set(groups.map(\.id))
        var knownSessionIDs = Set(allSessions.map(\.id))
        var restored: [SessionGroup] = []
        var unrestored: [PersistedGroup] = []
        for saved in state.groups where !knownGroupIDs.contains(saved.id) {
            var sessions: [TerminalSession] = []
            var skipped: [PersistedSession] = []
            for savedSession in saved.sessions where !knownSessionIDs.contains(savedSession.id) {
                guard let session = restoredSession(from: savedSession) else {
                    skipped.append(savedSession)
                    continue
                }
                knownSessionIDs.insert(session.id)
                sessions.append(session)
            }
            if !skipped.isEmpty {
                // A whole group keeps its id. Leftovers from a partly restored group need a new one, or the next
                // restore would see the id as already known and skip them.
                unrestored.append(sessions.isEmpty ? saved : PersistedGroup(id: UUID(), sessions: skipped, focusedSessionID: nil))
            }
            guard !sessions.isEmpty else { continue }
            knownGroupIDs.insert(saved.id)
            let focused = sessions.contains { $0.id == saved.focusedSessionID } ? saved.focusedSessionID : nil
            restored.append(SessionGroup(id: saved.id, sessions: sessions, focusedSessionID: focused))
        }
        unrestoredGroups = unrestored
        guard !restored.isEmpty else { return false }

        let restoredSessions = restored.flatMap(\.sessions)
        let quietIDs = Set(restoredSessions.map(\.id))
        restoreQuietSessionIDs.formUnion(quietIDs)
        projectOrder = sectionOrdered(projectOrder + restored)
        // Groups idle past the threshold since the last save go straight to Older.
        arrangeGroups(republish: true)
        for session in restoredSessions {
            session.start()
        }

        let target = restored.first(where: { $0.id == state.selectedGroupID }) ?? selectedGroup ?? restored.first
        if let session = target?.focusedSession {
            select(session)
        }
        recomputeVisibility()
        Task { [weak self] in
            try? await Task.sleep(for: Self.restoreQuietPeriod)
            self?.endRestoreQuietPeriod(for: quietIDs)
        }
        return true
    }

    /// Terminates every session. Called on quit after save().
    func terminateAll() {
        isTerminating = true
        saveTask?.cancel()
        saveTask = nil
        olderCheck?.cancel()
        olderCheck = nil
        cancellables.removeAll()
        attentionObservers.removeAll()
        for session in allSessions {
            session.onAttention = nil
            session.onExit = nil
            session.onFocus = nil
            session.onUse = nil
            session.terminate()
        }
        // The delayed SIGKILL in terminate() never runs once the app exits. Give jobs up to a second to leave, then
        // kill what remains so nothing outlives Conch holding a port.
        let hungUp = allSessions.compactMap(\.hungUpGroups)
        let jobs = hungUp.compactMap(\.job)
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, jobs.contains(where: { killpg($0, 0) == 0 }) {
            usleep(20_000)
        }
        hungUp.forEach(TerminalSession.killSurvivors)
        Notifier.shared.updateDockBadge(count: 0)
    }

    // MARK: Older

    /// The last time the session was typed into, printed counted output or was visible. A visible session counts as
    /// active right now, so the one the user is looking at never goes stale.
    func lastActive(of session: TerminalSession) -> Date {
        lastActive(of: session, at: now())
    }

    /// Moves groups that crossed the threshold into Older and active ones back out, then schedules the next check.
    /// Runs from a one-shot timer at the next crossing, never on a polling loop.
    func refreshOlder() {
        arrangeGroups(republish: false)
    }

    private func lastActive(of session: TerminalSession, at time: Date) -> Date {
        session.isVisibleToUser ? time : lastActiveTimes[session.id] ?? time
    }

    private func noteUse(_ session: TerminalSession, _ use: SessionUse) {
        // A restored session replays its conversation or prompt while the quiet period runs. That is not use.
        if use == .output, restoreQuietSessionIDs.contains(session.id) { return }
        lastActiveTimes[session.id] = now()
        // A recent group only moves its crossing later, which the scheduled check copes with when it fires. A group
        // in Older comes back at once.
        guard !olderGroupIDs.isEmpty, let group = group(containing: session), olderGroupIDs.contains(group.id) else {
            return
        }
        refreshOlder()
    }

    /// The selected group counts as in view for as long as it is selected, even while the app is in the background,
    /// so it never moves to Older. Leaving it, or picking one, stamps the time.
    private func noteSelectionChanged(from previous: UUID?) {
        let time = now()
        for group in projectOrder where group.id == previous || group.id == selectedGroupID {
            for session in group.sessions { lastActiveTimes[session.id] = time }
        }
        refreshOlder()
    }

    /// Recomputes which groups are in Older and publishes `groups` as the project sections followed by the Older
    /// groups, both in `projectOrder`. `republish` publishes even when nothing moved, for a structural change.
    private func arrangeGroups(republish: Bool) {
        let time = now()
        var older = Set<UUID>()
        var nextCrossing: Date?
        if settings.olderAfterHours > 0 {
            let threshold = TimeInterval(settings.olderAfterHours) * 3600
            for group in projectOrder where group.id != selectedGroupID && !group.sessions.isEmpty {
                let latest = group.sessions.map { lastActive(of: $0, at: time) }.max() ?? time
                let crossing = latest.addingTimeInterval(threshold)
                if crossing <= time {
                    older.insert(group.id)
                } else if nextCrossing.map({ crossing < $0 }) ?? true {
                    nextCrossing = crossing
                }
            }
        }
        scheduleOlderCheck(at: nextCrossing)
        let moved = older != olderGroupIDs
        guard moved || republish else { return }
        olderGroupIDs = older
        groups = projectOrder.filter { !older.contains($0.id) } + projectOrder.filter { older.contains($0.id) }
        // Keeps the saved last active times close to current when Conch does not quit cleanly.
        if moved { scheduleSave() }
    }

    private func scheduleOlderCheck(at date: Date?) {
        olderCheck?.cancel()
        olderCheck = nil
        nextOlderCheck = date
        guard let date, !isTerminating else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshOlder() }
        }
        olderCheck = item
        // Wall clock, so a Mac that slept through the crossing checks again as soon as it wakes. The extra second
        // makes sure the crossing has passed when it runs.
        let delay = max(date.timeIntervalSince(now()), 0) + 1
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + delay, execute: item)
    }

    // MARK: Private

    private func wire(_ session: TerminalSession) {
        session.onAttention = { [weak self] session, attention in
            self?.notify(session, attention)
        }
        session.onFocus = { [weak self] session in
            self?.sessionDidFocus(session)
        }
        session.onUse = { [weak self] session, use in
            self?.noteUse(session, use)
        }
        lastActiveTimes[session.id] = now()
        applyAppearance(to: session)

        // Deferred a turn because @Published emits before the new value is stored, so attentionCount would be stale.
        attentionObservers[session.id] = session.$attention
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak session] attention in
                guard let self else { return }
                if attention == .none, let session {
                    Notifier.shared.clear(sessionID: session.id)
                }
                if let session { self.noteAttentionRaised(attention, sessionID: session.id) }
                Notifier.shared.updateDockBadge(count: self.attentionCount)
                self.publishWaitingCount()
            }
    }

    /// Keeps the time of the first emit at each rank, so a bell that later gains its OSC message keeps its place.
    private func noteAttentionRaised(_ attention: Attention, sessionID: UUID) {
        guard attention.rank >= Attention.done.rank else {
            attentionRaised.removeValue(forKey: sessionID)
            return
        }
        if attentionRaised[sessionID]?.rank != attention.rank {
            attentionRaised[sessionID] = (attention.rank, Date())
        }
    }

    private func publishWaitingCount() {
        let count = attentionCount
        if waitingCountPublisher.value != count { waitingCountPublisher.send(count) }
    }

    private func applyAppearance(to session: TerminalSession) {
        session.applyAppearance(fontSize: CGFloat(settings.fontSize), optionAsMeta: settings.optionAsMeta)
    }

    private func applyAppearanceIfSettingsChanged() {
        if let applied = appliedAppearance, applied.fontSize == settings.fontSize, applied.optionAsMeta == settings.optionAsMeta {
            return
        }
        applyAppearanceToAll()
    }

    private func notify(_ session: TerminalSession, _ attention: Attention) {
        let text: String
        switch attention {
        case .done:
            guard settings.notifyWhenDone, !restoreQuietSessionIDs.contains(session.id) else { return }
            text = "Finished"
        case .needsInput(let message):
            guard settings.notifyOnBell else { return }
            let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            text = trimmed.isEmpty ? "Waiting for your input" : trimmed
        case .none, .unread:
            return
        }
        let project = Self.sectionName(forRoot: projectRoot(for: session.spec.cwd))
        Notifier.shared.post(title: session.displayName, body: "\(project): \(text)", sessionID: session.id)
    }

    private func sessionDidFocus(_ session: TerminalSession) {
        guard let group = group(containing: session) else { return }
        markFocused(session, in: group)
        selectedGroupID = group.id
    }

    private func markFocused(_ session: TerminalSession, in group: SessionGroup) {
        guard group.focusedSessionID != session.id else { return }
        // The sidebar highlights the active session's row, which depends on this group-level value.
        objectWillChange.send()
        group.focusedSessionID = session.id
        scheduleSave()
    }

    // The window container may attach a new session's view a run loop turn after the store publishes it.
    private func focusWhenAttached(_ session: TerminalSession) {
        if session.view.window != nil {
            session.focus()
            return
        }
        Task { [weak self, weak session] in
            guard let self, let session, self.activeSession === session else { return }
            session.focus()
        }
    }

    private func refreshTick() {
        for group in groups {
            let isSelected = group.id == selectedGroupID
            for session in group.sessions where !session.activity.isExited && (isSelected || session.foregroundProcess != nil) {
                session.refreshProcessInfo()
            }
        }
        recomputeVisibility()
    }

    func scheduleSave() {
        guard !isTerminating else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Ends the quiet period of one restore's sessions only, so an earlier restore's timer cannot cut a later one short.
    private func endRestoreQuietPeriod(for ids: Set<UUID>) {
        for id in ids where restoreQuietSessionIDs.contains(id) {
            guard let session = session(withID: id) else { continue }
            if session.attention == .unread || session.attention == .done {
                session.clearAttention()
            }
        }
        restoreQuietSessionIDs.subtract(ids)
    }

    private func restoredSession(from saved: PersistedSession) -> TerminalSession? {
        var spec = saved.spec
        if !Self.isDirectory(spec.cwd) {
            guard spec.kind == .shell else { return nil }
            spec = .shell(NSHomeDirectory())
        }
        let start = saved.lastDirectory.flatMap { Self.isDirectory($0) ? $0 : nil } ?? spec.cwd
        let session = TerminalSession(
            id: saved.id,
            spec: spec,
            customName: saved.customName,
            lastTitle: saved.lastTitle,
            startDirectory: start,
            restoring: true
        )
        wire(session)
        // A state file from before the Older section has no time, so the session counts as active at launch.
        if let lastActive = saved.lastActive { lastActiveTimes[session.id] = lastActive }
        return session
    }

    /// Directory for a new session: `dir` when it exists, else `defaultDirectory()` with a fresh read of the
    /// active session's cwd (so Cmd+N right after a `cd` lands in the new folder).
    func resolvedDirectory(_ dir: String?) -> String {
        if let dir, !dir.isEmpty {
            let path = (dir.expandingTilde as NSString).standardizingPath
            if Self.isDirectory(path) { return path }
        }
        if let active = activeSession, !active.activity.isExited {
            active.refreshProcessInfo()
        }
        return defaultDirectory()
    }

    /// Where in `projectOrder` a new group with this project root goes: right after the selected group when it is in
    /// the same project, else at the end of its project's block, else right after the selected group's block. On
    /// screen that is the same place, because Older groups are only left out of their project's run.
    private func insertionIndex(forRoot root: String) -> Int {
        if let selected = projectOrder.firstIndex(where: { $0.id == selectedGroupID }) {
            let selectedRoot = projectRoot(of: projectOrder[selected])
            if selectedRoot == root { return selected + 1 }
            if let last = projectOrder.lastIndex(where: { projectRoot(of: $0) == root }) { return last + 1 }
            if let last = projectOrder.lastIndex(where: { projectRoot(of: $0) == selectedRoot }) { return last + 1 }
        }
        if let last = projectOrder.lastIndex(where: { projectRoot(of: $0) == root }) { return last + 1 }
        return projectOrder.count
    }

    /// Stable regroup so each project's groups are contiguous, projects in order of first appearance.
    private func sectionOrdered(_ list: [SessionGroup]) -> [SessionGroup] {
        groupedByRoot(list).flatMap(\.groups)
    }

    private func groupedByRoot(_ list: [SessionGroup]) -> [(root: String, groups: [SessionGroup])] {
        var roots: [String] = []
        var members: [String: [SessionGroup]] = [:]
        for group in list {
            let root = projectRoot(of: group)
            if members[root] == nil { roots.append(root) }
            members[root, default: []].append(group)
        }
        return roots.map { (root: $0, groups: members[$0] ?? []) }
    }

    private func projectRoot(of group: SessionGroup) -> String {
        projectRoot(for: group.sessions.first?.spec.cwd ?? NSHomeDirectory())
    }

    /// Nearest ancestor (or the path itself) containing .git, else the path. A linked git worktree counts as its main
    /// repository, so worktree sessions sit in their repo's section. Cached per path because the sidebar reads
    /// `sections` on every render.
    private func projectRoot(for path: String) -> String {
        if let cached = projectRootCache[path] { return cached }
        let root = LaunchCommand.worktreeRepositoryRoot(for: path) ?? path
        projectRootCache[path] = root
        return root
    }

    private static func sectionName(forRoot root: String) -> String {
        root == NSHomeDirectory() ? "~" : root.lastPathComponentOrSelf
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func isShowing(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private static func wrap(_ index: Int, count: Int) -> Int {
        ((index % count) + count) % count
    }
}
