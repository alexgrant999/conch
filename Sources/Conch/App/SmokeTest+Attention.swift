import AppKit

// Owner: feature/attention builder.

extension SmokeTest {
    /// Smoke checks for this feature. Record each with `record("<number> <name>", ok, detail)`.
    ///
    /// Three hidden sessions get attention in this order: B rings the bell, C finishes a long run of output (done),
    /// then A rings the bell. The jump order must be B, A, C: waiting before finished even though C finished before
    /// A rang, oldest first within each, and neither matches the sidebar order A, B, C.
    func checkAttentionJump(directory: String) async {
        let name = "12 attention jump"
        let started = Date()
        let previous = store.activeSession

        // Each new shell selects its own new group, so after `front` the other three are hidden.
        let a = store.newShell(in: directory)
        let b = store.newShell(in: directory)
        let c = store.newShell(in: directory)
        let front = store.newShell(in: directory)
        let mine = [a, b, c, front]
        for (session, label) in zip(mine, ["attention-a", "attention-b", "attention-c", "attention-front"]) {
            store.rename(session, to: label)
        }
        func finish(_ ok: Bool, _ detail: String) {
            mine.forEach(store.close)
            if let previous, store.session(withID: previous.id) != nil { store.select(previous) }
            record(name, ok, detail + String(format: " (%.1f s)", Date().timeIntervalSince(started)))
        }

        let prompted = await waitUntil(5) {
            mine.allSatisfy { !$0.bufferText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        guard prompted else { return finish(false, "shells did not start") }
        await pause(0.3)

        // A busy streak of 4 s or more that ends while hidden marks a session done, so C prints for about 5 s.
        c.send(text: "for i in {1..25}; do echo tick$i; sleep 0.2; done\r")
        b.send(text: "printf '\\a'\r")
        guard await waitUntil(3, { b.attention.rank == Attention.needsInput(message: nil).rank }) else {
            return finish(false, "B bell gave attention \(b.attention)")
        }
        guard await waitUntil(10, { c.attention == .done }) else {
            return finish(false, "C output gave attention \(c.attention), activity \(c.activity)")
        }
        a.send(text: "printf '\\a'\r")
        guard await waitUntil(3, { a.attention.rank == Attention.needsInput(message: nil).rank }) else {
            return finish(false, "A bell gave attention \(a.attention)")
        }
        // The store records times and publishes the count one main queue turn after attention changes.
        let published = await waitUntil(1) { store.waitingCountPublisher.value == store.attentionCount }

        let label: (TerminalSession) -> String = { $0.displayName }
        let waiting = store.waitingSessions
        let order = waiting.filter { session in mine.contains { $0 === session } }
        guard order.map(\.id) == [b, a, c].map(\.id) else {
            return finish(false, "order \(order.map(label)), expected attention-b, attention-a, attention-c")
        }
        guard published, waiting.count == store.attentionCount else {
            return finish(false, "waiting \(waiting.count), dock badge count \(store.attentionCount), "
                + "published \(store.waitingCountPublisher.value)")
        }

        // The menu bar item's menu and the palette command describe the same sessions.
        let menu = NSMenu()
        AttentionStatusItem.populate(menu, store: store, target: .shared)
        let menuIDs = menu.items.compactMap { $0.representedObject as? UUID }
        guard menuIDs == waiting.map(\.id) else {
            let titles = menu.items.filter { $0.representedObject is UUID }.map(\.title)
            return finish(false, "menu bar items \(titles), expected \(waiting.map(label))")
        }
        let palette = PaletteModel(mode: .commands, store: store, projects: [])
        let paletteDetail = palette.items.first { $0.id == "cmd:Jump to Next Waiting" }?.detail
        guard paletteDetail == "\(waiting.count) waiting" else {
            return finish(false, "palette detail \(paletteDetail ?? "missing"), expected \(waiting.count) waiting")
        }

        // A smoke run starts in the background and macOS does not let it take focus from the user's app, so a session
        // it jumps to never becomes visible on its own. `reveal` then does what recomputeVisibility does once the app
        // is active: the selected group shows, which clears its attention.
        let appActive = NSApp.isActive
        let reveal = { [store] in
            guard !appActive else { return }
            store.selectedGroup?.sessions.forEach { $0.isVisibleToUser = true }
            store.recomputeVisibility()
        }

        // The store's jump, as Cmd+J runs it minus showMainWindow, which would pull focus from the user's app on
        // every jump. Pressing again moves on, even while the first session is not showing yet.
        let first = store.selectNextWaiting()
        let second = store.selectNextWaiting()
        guard first === waiting[0], second === waiting[1] else {
            return finish(false, "first two jumps went to \(first.map(label) ?? "nothing"), \(second.map(label) ?? "nothing"), "
                + "expected \(label(waiting[0])), \(label(waiting[1]))")
        }
        // Choosing a session by hand ends the repeat, so the next jump starts from the top again.
        store.select(front)
        let remaining = store.waitingSessions
        let expectedRemaining = appActive ? Array(waiting.dropFirst(2)) : waiting
        guard remaining.map(\.id) == expectedRemaining.map(\.id) else {
            return finish(false, "still waiting \(remaining.map(label)), expected \(expectedRemaining.map(label))")
        }

        // Each jump selects the next session, and showing it clears its attention.
        for expected in remaining {
            guard let jumped = store.selectNextWaiting(), jumped === expected else {
                return finish(false, "jump went to \(store.activeSession.map(label) ?? "nothing"), expected \(label(expected))")
            }
            guard store.activeSession === expected, store.selectedGroup?.sessions.contains(where: { $0 === expected }) == true else {
                return finish(false, "after jumping to \(label(expected)) the active session is \(store.activeSession.map(label) ?? "none")")
            }
            reveal()
            guard await waitUntil(2, { expected.attention == .none }) else {
                return finish(false, "\(label(expected)) kept attention \(expected.attention) after the jump "
                    + "(app active \(appActive), visible \(expected.isVisibleToUser))")
            }
        }
        if let extra = store.selectNextWaiting() {
            return finish(false, "\(label(extra)) still waiting after every jump")
        }
        // With nothing waiting, Cmd+J says so over the window instead of only beeping.
        let windowShown = AppActions.mainWindow.map { $0.isVisible && !$0.isMiniaturized } ?? false
        let jumped = AttentionJump.next(store: store)
        if jumped != nil { return finish(false, "Cmd+J jumped to \(jumped.map(label) ?? "?") with nothing waiting") }
        if windowShown, Toast.currentMessage != AttentionJump.nothingWaitingMessage {
            return finish(false, "Cmd+J with nothing waiting showed \(Toast.currentMessage ?? "no message")")
        }
        Toast.dismiss()

        // The shortcuts sheet lists what the menus really bind, and opens and closes.
        let listed = ShortcutsOverlay.groups().flatMap(\.entries)
        for (keys, title) in [("⌘J", "Jump to Next Waiting"), ("⇧⌘O", "Open Project Folder"), ("⌘/", "Keyboard Shortcuts"),
                              ("⌥⌘N", "New Claude in Worktree"), ("⌘1 to ⌘9", "Jump to a session")]
        where !listed.contains(ShortcutEntry(keys: keys, title: title)) {
            return finish(false, "shortcuts sheet lacks \(keys) \(title): \(listed.map { $0.keys + " " + $0.title })")
        }
        if windowShown {
            ShortcutsOverlay.show()
            guard ShortcutsOverlay.isShown else { return finish(false, "shortcuts sheet did not open") }
            if let path = ProcessInfo.processInfo.environment["CONCH_SMOKE_SNAPSHOT"], let png = ShortcutsOverlay.snapshot() {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            ShortcutsOverlay.toggle()
            if ShortcutsOverlay.isShown { return finish(false, "shortcuts sheet did not close") }
        }
        _ = await waitUntil(1) { store.waitingCountPublisher.value == 0 }
        finish(store.waitingCountPublisher.value == 0,
               "order \(waiting.map(label).joined(separator: ", ")), repeat press moves on, all cleared, menu and palette "
                   + "agree, count \(store.waitingCountPublisher.value), app active \(appActive)"
                   + (appActive ? "" : " so showing was simulated"))
    }
}
