import Foundation

// Owner: older builder (feature/older-section).

extension SmokeTest {
    /// Smoke check 18. Moves the store's clock forward instead of waiting hours, and runs the check the scheduled
    /// timer would run at that moment. Typing is text sent the way Conch types it. Leaves the clock, the setting and
    /// the selection as it found them.
    ///
    /// Three shells in project older-alpha (a1, a2, a3) and one in older-beta (b1, kept selected). a2 goes idle while
    /// a1 and a3 are used, so it has to come back between them.
    func checkOlder(directory: String) async {
        let name = "18 older section"
        let started = Date()
        var failures: [String] = []
        let previous = store.activeSession
        let settings = store.settings
        let originalHours = settings.olderAfterHours
        let hour: TimeInterval = 3600
        var offset: TimeInterval = 0
        store.now = { Date().addingTimeInterval(offset) }
        settings.olderAfterHours = 6

        let alpha = (directory as NSString).appendingPathComponent("older-alpha")
        let beta = (directory as NSString).appendingPathComponent("older-beta")
        for folder in [alpha, beta] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        let a1 = store.newShell(in: alpha), a2 = store.newShell(in: alpha), a3 = store.newShell(in: alpha)
        let b1 = store.newShell(in: beta)
        var created = [a1, a2, a3, b1]
        for (session, label) in zip(created, ["older-a1", "older-a2", "older-a3", "older-b1"]) {
            store.rename(session, to: label)
        }

        func finish(_ detail: String) {
            for session in created where store.session(withID: session.id) === session { store.close(session) }
            store.now = { Date() }
            settings.olderAfterHours = originalHours
            store.refreshOlder()
            if let previous, store.session(withID: previous.id) != nil { store.select(previous) }
            let time = String(format: " (%.1f s)", Date().timeIntervalSince(started))
            record(name, failures.isEmpty, (failures.isEmpty ? detail : failures.joined(separator: "; ")) + time)
        }
        let mine: (TerminalSession) -> Bool = { session in created.contains { $0 === session } }
        func names(_ groups: [SessionGroup]) -> [String] {
            groups.flatMap(\.sessions).filter(mine).map(\.displayName)
        }
        func alphaRow() -> [String] { names(store.sections.first { $0.id == alpha }?.groups ?? []) }
        func olderRow() -> [String] { names(store.olderGroups) }
        /// `groups` and `allSessions` must be exactly what the sidebar draws: the project sections, then Older.
        func checkOrder(_ step: String) {
            let visual = store.sections.flatMap(\.groups) + store.olderGroups
            if visual.map(\.id) != store.groups.map(\.id)
                || visual.flatMap(\.sessions).map(\.id) != store.allSessions.map(\.id) {
                failures.append("\(step): groups \(store.groups.flatMap(\.sessions).map(\.displayName)) are not the "
                    + "sidebar order \(visual.flatMap(\.sessions).map(\.displayName))")
            }
        }
        func expect(_ step: String, alpha expectedAlpha: [String], older expectedOlder: [String]) {
            if alphaRow() != expectedAlpha || olderRow() != expectedOlder {
                failures.append("\(step): older-alpha \(alphaRow()) and Older \(olderRow()), expected \(expectedAlpha) "
                    + "and \(expectedOlder)")
            }
            checkOrder(step)
        }
        func near(_ date: Date?, _ expected: Date, within seconds: TimeInterval = 0.01) -> Bool {
            date.map { abs($0.timeIntervalSince(expected)) <= seconds } ?? false
        }

        let prompted = await waitUntil(6) {
            created.allSatisfy { !$0.bufferText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        guard prompted else {
            failures.append("shells did not start")
            return finish("")
        }
        // Lets the prompt output land and the 4 Hz activity reading count it before the clock moves.
        await pause(1)

        // The next check is scheduled for the first crossing, at most 6 hours away, and nothing is Older yet.
        store.refreshOlder()
        let firstCheck = store.nextOlderCheck
        if firstCheck.map({ $0 <= store.now() || $0 > store.now().addingTimeInterval(6 * hour + 1) }) ?? true {
            failures.append("next check \(String(describing: firstCheck)), expected within 6 hours")
        }
        expect("fresh", alpha: ["older-a1", "older-a2", "older-a3"], older: [])

        // 7 hours later only a1 and a3 were typed into. a2 crosses the threshold and moves to Older, and b1 stays
        // because it is selected. The next check is now 6 hours after the typing.
        offset = 7 * hour
        a1.send(text: "\r")
        a3.send(text: "\r")
        store.refreshOlder()
        expect("a2 idle 7 hours", alpha: ["older-a1", "older-a3"], older: ["older-a2"])
        if store.olderGroups.contains(where: { $0.sessions.contains { $0 === b1 } }) {
            failures.append("the selected group moved to Older")
        }
        if !near(store.nextOlderCheck, store.now().addingTimeInterval(6 * hour), within: 2) {
            failures.append("next check \(String(describing: store.nextOlderCheck)), expected 6 hours after the typing")
        }
        if let group = store.group(containing: a2) {
            let project = store.project(of: group)
            let detail = SidebarPath.olderDetail(project: project.name, root: project.root,
                                                 directory: a2.currentDirectory, status: nil)
            let busy = SidebarPath.olderDetail(project: project.name, root: project.root,
                                               directory: a2.currentDirectory, status: "node")
            if project.name != "older-alpha" || !detail.hasPrefix("older-alpha") || busy != "older-alpha · node" {
                failures.append("Older row for a2 reads \(detail) and \(busy), project \(project.name)")
            }
        }

        // Typing into a2 brings it straight back, between a1 and a3 where it was.
        a2.send(text: "\r")
        expect("typed into a2", alpha: ["older-a1", "older-a2", "older-a3"], older: [])

        // Idle again, then selected: back in place, and b1, which it replaced as the selection, stays recent.
        offset = 14 * hour
        a1.send(text: "\r")
        a3.send(text: "\r")
        store.refreshOlder()
        expect("a2 idle again", alpha: ["older-a1", "older-a3"], older: ["older-a2"])
        store.select(a2)
        expect("selected a2", alpha: ["older-a1", "older-a2", "older-a3"], older: [])
        if store.activeSession !== a2 { failures.append("selecting a2 left \(store.activeSession?.displayName ?? "nothing") active") }
        store.select(b1)

        // A visible session counts as active the whole time it shows, and from the moment it hides. Shown the way
        // recomputeVisibility shows the selected group once the app is active, which a background smoke run is not.
        // No await until it hides, so the store's own visibility pass cannot undo it.
        offset = 21 * hour
        a1.send(text: "\r")
        a3.isVisibleToUser = true
        offset = 28 * hour
        store.refreshOlder()
        expect("a3 visible 7 hours", alpha: ["older-a3"], older: ["older-a1", "older-a2"])
        let hidden = store.now()
        a3.isVisibleToUser = false
        if !near(store.lastActive(of: a3), hidden, within: 1) {
            failures.append("hiding a3 stamped \(store.lastActive(of: a3)), expected \(hidden)")
        }
        offset = 35 * hour
        store.refreshOlder()
        expect("a3 hidden 7 hours", alpha: [], older: ["older-a1", "older-a2", "older-a3"])

        // Last active times survive a save and load, and a restored session's replayed output does not count. The
        // replay is a startup command that prints half a second in, the way a dev server does on every relaunch.
        var replaySpec = LaunchSpec.shell(alpha)
        replaySpec.command = "sleep 0.5; echo CONCH_REPLAY_$((6*7))"
        let replay = store.newSession(replaySpec, customName: "older-replay", select: false)
        created.append(replay)
        let ranFirst = await waitUntil(6) { replay.bufferText().contains("CONCH_REPLAY_42") }
        await pause(0.6)
        if !ranFirst { failures.append("the replay pane's startup command did not run") }
        store.save()
        // Saved in project order, so a1 to a3, in Older now, keep their places ahead of the replay pane and b1.
        let savedOrder = Persistence.load()?.groups.flatMap(\.sessions).map(\.id).filter { id in created.contains { $0.id == id } }
        if savedOrder != [a1, a2, a3, replay, b1].map(\.id) {
            let label: (UUID) -> String = { id in created.first { $0.id == id }?.displayName ?? id.uuidString }
            failures.append("saved order \((savedOrder ?? []).map(label)), expected older-a1, older-a2, older-a3, older-replay, older-b1")
        }
        let saved = Persistence.load()?.groups.flatMap(\.sessions).first { $0.id == replay.id }
        let replayActive = store.lastActive(of: replay)
        if !near(saved?.lastActive, replayActive) {
            failures.append("saved last active \(String(describing: saved?.lastActive)), expected \(replayActive)")
        }
        store.close(replay)
        offset = 42 * hour
        store.restore()
        guard let restored = store.session(withID: replay.id) else {
            failures.append("the replay pane did not restore")
            return finish("")
        }
        created.append(restored)
        let replayed = await waitUntil(6) { restored.bufferText().contains("CONCH_REPLAY_42") }
        await pause(0.6)
        store.refreshOlder()
        // Counted output raises unread on a hidden session, which shows the replay was taken as output at all.
        if !replayed || restored.attention != .unread {
            failures.append("the restored pane's replay was not counted as output (printed \(replayed), attention "
                + "\(restored.attention))")
        } else if !near(store.lastActive(of: restored), replayActive) {
            failures.append("restore replay moved the last active time from \(replayActive) to "
                + "\(store.lastActive(of: restored))")
        }
        if !olderRow().contains("older-replay") { failures.append("the restored pane is not in Older: \(olderRow())") }
        checkOrder("restored pane")

        // A state file from before the field loads, and its sessions count as active at launch.
        let oldID = UUID()
        let oldState = PersistedState(groups: [PersistedGroup(
            id: UUID(), sessions: [PersistedSession(id: oldID, customName: "older-old", lastTitle: nil, lastDirectory: beta, spec: .shell(beta))],
            focusedSessionID: oldID)], selectedGroupID: nil)
        if let data = try? JSONEncoder().encode(oldState), let text = String(data: data, encoding: .utf8) {
            let decoded = try? JSONDecoder().decode(PersistedState.self, from: data)
            if text.contains("lastActive") || decoded?.groups.first?.sessions.first?.lastActive != nil {
                failures.append("a session without a last active time still writes or reads one: \(text)")
            }
            try? data.write(to: Persistence.stateURL, options: .atomic)
        }
        store.restore()
        if let old = store.session(withID: oldID) {
            created.append(old)
            if !near(store.lastActive(of: old), store.now(), within: 2) {
                failures.append("old state session last active \(store.lastActive(of: old)), expected launch time \(store.now())")
            }
            if olderRow().contains("older-old") { failures.append("old state session went straight to Older") }
        } else {
            failures.append("the old state file did not restore")
        }
        checkOrder("old state file")

        // Off: no Older section, every group back in its project, nothing scheduled.
        settings.olderAfterHours = 0
        let cleared = await waitUntil(1) { store.olderGroups.isEmpty }
        if !cleared || store.nextOlderCheck != nil {
            failures.append("with the setting off Older still holds \(olderRow()), next check \(String(describing: store.nextOlderCheck))")
        }
        let restoredAlpha = Set(alphaRow())
        if restoredAlpha != ["older-a1", "older-a2", "older-a3", "older-replay"] {
            failures.append("with the setting off older-alpha holds \(alphaRow())")
        }
        checkOrder("setting off")

        finish("a2 moved to Older and back to its place on typing and on selection, a visible session stayed, restore "
            + "replay did not count, times survived save and load, an old state file loaded, Off shows no Older section")
    }
}
