import Combine
import Foundation

// Owner: usage builder (feature/usage-bars).

extension SmokeTest {
    /// Smoke check 17. Feeds UsageMonitor synthetic statusline reports, parsed by ContextReading as real ones are.
    /// Never runs claude and never touches the network.
    func checkUsage(directory: String) async {
        var failures: [String] = []
        let file = UsageMonitor.defaultFileURL
        let stateFolder = Persistence.stateURL.deletingLastPathComponent().standardizedFileURL.path
        if file.deletingLastPathComponent().standardizedFileURL.path != stateFolder {
            failures.append("usage.json is at \(file.path), not next to the state file")
        }
        try? FileManager.default.removeItem(at: file)
        let monitor = UsageMonitor(fileURL: file)
        let now = Date()
        let fiveHourReset = Date(timeIntervalSince1970: (now.timeIntervalSince1970 + 2 * 3600).rounded())
        let weekReset = Date(timeIntervalSince1970: (now.timeIntervalSince1970 + 3 * 86_400).rounded())
        let opus = ("claude-opus-5-5", "Opus 5.5"), fable = ("claude-fable-5-1", "Fable 5.1")
        let haiku = ("claude-haiku-5", "Haiku 5")
        func feed(_ target: UsageMonitor, _ session: UUID, _ conversation: UUID, prompt: String?, total: Double,
                  model: (String, String)? = nil, fiveHour: (Double, Date)? = nil, sevenDay: (Double, Date)? = nil,
                  tokens: UsageTokens? = nil, at date: Date? = nil) {
            let data = usageReport(conversation: conversation, prompt: prompt, total: total, model: model ?? opus,
                                   fiveHour: fiveHour, sevenDay: sevenDay, tokens: tokens)
            guard let reading = ContextReading(json: data) else {
                failures.append("a report did not parse")
                return
            }
            target.record(reading, updated: date ?? now, session: session)
        }
        func near(_ value: Double?, _ expected: Double) -> Bool {
            value.map { abs($0 - expected) < 0.000_001 } ?? false
        }

        // Limits: the newest figure wins, a lower one from the same window is stale, an earlier window never wins.
        let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
        let (conversationA, conversationB) = (UUID(), UUID())
        feed(monitor, a, conversationA, prompt: nil, total: 1.00, fiveHour: (30, fiveHourReset), sevenDay: (20, weekReset))
        feed(monitor, b, conversationB, prompt: nil, total: 5.00, model: fable, fiveHour: (35, fiveHourReset))
        feed(monitor, a, conversationA, prompt: nil, total: 1.00, fiveHour: (30, fiveHourReset))
        feed(monitor, b, conversationB, prompt: nil, total: 5.00, model: fable, sevenDay: (90, now.addingTimeInterval(-60)))
        if monitor.fiveHour()?.usedPercent != 35 || monitor.fiveHour()?.resetsAt != fiveHourReset {
            failures.append("5-hour limit \(String(describing: monitor.fiveHour())), expected 35% from the newest report")
        }
        if monitor.sevenDay()?.usedPercent != 20 { failures.append("weekly limit \(String(describing: monitor.sevenDay())), expected 20% (the reset one ignored)") }
        let expiredMonitor = UsageMonitor(fileURL: URL(fileURLWithPath: directory).appendingPathComponent("usage-expired.json"))
        feed(expiredMonitor, a, conversationA, prompt: nil, total: 1, fiveHour: (50, now.addingTimeInterval(-60)))
        if expiredMonitor.fiveHour() != nil { failures.append("a limit whose resets_at has passed still shows") }

        failures += limitDropFailures(directory: directory, feed: feed, fiveHourReset: fiveHourReset, now: now)

        // Last prompt: from the last report of the previous prompt id. The 5-hour start is the account's figure then.
        let tokens = UsageTokens(input: 2, cacheRead: 227_511, cacheWrite: 3_283, output: 406)
        feed(monitor, a, conversationA, prompt: "p1", total: 1.10, fiveHour: (35, fiveHourReset))
        feed(monitor, a, conversationA, prompt: "p1", total: 1.42, fiveHour: (38, fiveHourReset), tokens: tokens)
        let first = monitor.lastPrompt(for: a)
        if !near(first?.cost, 0.42) || first?.fiveHourChange != 3 || first?.tokens != tokens {
            failures.append("first prompt \(String(describing: first)), expected $0.42, 3 points and the call's tokens")
        }
        feed(monitor, a, conversationA, prompt: "p2", total: 1.50)
        if !near(monitor.lastPrompt(for: a)?.cost, 0.08) { failures.append("second prompt cost \(String(describing: monitor.lastPrompt(for: a)?.cost)), expected 0.08") }

        // A prompt already running in the first report has no baseline, unless nothing had been spent yet.
        let conversationC = UUID()
        feed(monitor, c, conversationC, prompt: "q1", total: 2.00)
        feed(monitor, c, conversationC, prompt: "q1", total: 2.30)
        if monitor.lastPrompt(for: c)?.cost != nil { failures.append("first report mid-prompt gave a cost") }
        feed(monitor, c, conversationC, prompt: "q2", total: 2.50)
        if !near(monitor.lastPrompt(for: c)?.cost, 0.20) { failures.append("prompt after a baseline \(String(describing: monitor.lastPrompt(for: c)?.cost)), expected 0.20") }
        let conversationD = UUID()
        feed(monitor, d, conversationD, prompt: "r1", total: 0)
        feed(monitor, d, conversationD, prompt: "r1", total: 0.25)
        if !near(monitor.lastPrompt(for: d)?.cost, 0.25) { failures.append("prompt from a zero total \(String(describing: monitor.lastPrompt(for: d)?.cost)), expected 0.25") }

        // A drop in the total (/clear, a new conversation) resets the baseline instead of going negative.
        feed(monitor, a, conversationA, prompt: "p2", total: 0.05)
        if let cost = monitor.lastPrompt(for: a)?.cost, cost < 0 || near(cost, 0.08) {
            failures.append("after a drop the last prompt reads \(cost)")
        }
        feed(monitor, a, conversationA, prompt: "p3", total: 0.25)
        if !near(monitor.lastPrompt(for: a)?.cost, 0.20) { failures.append("prompt after a drop \(String(describing: monitor.lastPrompt(for: a)?.cost)), expected 0.20") }

        // By main model: positive deltas only, each to the newer report's model.
        feed(monitor, b, conversationB, prompt: "f1", total: 5.60, model: fable)
        feed(monitor, b, conversationB, prompt: "f2", total: 5.70)
        let today = monitor.costs(for: .today)
        // Opus: a 0.10 + 0.32 + 0.08 + 0.20, c 0.30 + 0.20, d 0.25, b 0.10 after its switch. Fable: b 0.60.
        if today.map(\.name) != ["Opus 5.5", "Fable 5.1"] || !near(today.first?.cost, 1.55) || !near(today.last?.cost, 0.60) {
            failures.append("today by main model \(today.map { "\($0.name) \($0.cost)" }), expected Opus 1.55 then Fable 0.60")
        }

        // This week runs from the weekly window's start: 4 days ago here, so a cost from 5 days ago is left out.
        let e = UUID(), conversationE = UUID()
        feed(monitor, e, conversationE, prompt: nil, total: 10, model: haiku, at: now.addingTimeInterval(-5 * 86_400))
        feed(monitor, e, conversationE, prompt: "w1", total: 10.40, model: haiku, at: now.addingTimeInterval(-5 * 86_400 + 60))
        feed(monitor, e, conversationE, prompt: "w2", total: 10.90, model: haiku, at: now.addingTimeInterval(-2 * 86_400))
        let week = monitor.costs(for: .week)
        if !near(week.first { $0.id == haiku.0 }?.cost, 0.50) || !near(week.first { $0.id == opus.0 }?.cost, 1.55) {
            failures.append("this week by main model \(week.map { "\($0.name) \($0.cost)" }), expected Haiku 0.50 and Opus 1.55")
        }
        if today.contains(where: { $0.id == haiku.0 }) { failures.append("an earlier day counted as today") }

        // Another conversation in the same session (/resume) restarts the baseline, and its total is not a cost.
        feed(monitor, c, UUID(), prompt: "q3", total: 9.00)
        if monitor.lastPrompt(for: c)?.cost != nil || !near(monitor.costs(for: .today).first?.cost, 1.55) {
            failures.append("a conversation change counted as spend")
        }

        // usage.json round trip, with days past the 35 kept dropped.
        let f = UUID(), conversationF = UUID(), old = now.addingTimeInterval(-40 * 86_400)
        feed(monitor, f, conversationF, prompt: nil, total: 1, at: old)
        feed(monitor, f, conversationF, prompt: "x", total: 2, at: old)
        monitor.saveNow()
        let reloaded = UsageMonitor(fileURL: file)
        if !FileManager.default.fileExists(atPath: file.path) {
            failures.append("usage.json was not written to \(file.path)")
        } else {
            if reloaded.fiveHour()?.usedPercent != 38 || reloaded.fiveHour()?.resetsAt != fiveHourReset
                || reloaded.sevenDay()?.usedPercent != 20 || reloaded.sevenDay()?.resetsAt != weekReset {
                failures.append("limits read back as \(String(describing: reloaded.fiveHour())), \(String(describing: reloaded.sevenDay()))")
            }
            if reloaded.costs(for: .today) != today { failures.append("today read back as \(reloaded.costs(for: .today))") }
            if reloaded.costs(for: .week) != week { failures.append("this week read back differently") }
            if reloaded.days[UsageMonitor.dayKey(old)] != nil { failures.append("a day older than 35 days was kept") }
        }

        if UsageFormat.cost(0.42) != "$0.42" || UsageFormat.cost(0.004) != "<$0.01" || UsageFormat.cost(76.18) != "$76.18" {
            failures.append("cost format: \(UsageFormat.cost(0.42)), \(UsageFormat.cost(0.004)), \(UsageFormat.cost(76.18))")
        }
        failures += await checkUsageFeed(directory: directory)
        failures += await checkUsageSetting()

        record("17 usage", failures.isEmpty,
               failures.isEmpty ? "limits (with drops after a call), expiry, last prompt, cost drop, main model totals, week window and usage.json all hold"
                   : failures.joined(separator: "; "))
    }

    /// A lower figure in the same window counts only from a report that followed an API call (the session's total
    /// went up since its previous report) and is not older than the newest such report. A repeated figure changes
    /// nothing, and a usage.json from before "seen" was dropped still loads.
    private func limitDropFailures(directory: String,
                                   feed: (UsageMonitor, UUID, UUID, String?, Double, (String, String)?, (Double, Date)?,
                                          (Double, Date)?, UsageTokens?, Date?) -> Void,
                                   fiveHourReset: Date, now: Date) -> [String] {
        var failures: [String] = []
        let file = URL(fileURLWithPath: directory).appendingPathComponent("usage-drop.json")
        try? FileManager.default.removeItem(at: file)
        let monitor = UsageMonitor(fileURL: file)
        func report(_ session: UUID, _ conversation: UUID, total: Double, percent: Double, secondsAgo: Double,
                    reset: Date? = nil) {
            feed(monitor, session, conversation, "p", total, nil, (percent, reset ?? fiveHourReset), nil, nil,
                 now.addingTimeInterval(-secondsAgo))
        }
        func expect(_ percent: Double, _ why: String) {
            if monitor.fiveHour()?.usedPercent != percent {
                failures.append("\(why): 5-hour \(monitor.fiveHour()?.usedPercent ?? -1), expected \(percent)")
            }
        }
        let (g, h, k) = (UUID(), UUID(), UUID())
        let (conversationG, conversationH, conversationK) = (UUID(), UUID(), UUID())
        report(g, conversationG, total: 1.00, percent: 60, secondsAgo: 50)
        report(g, conversationG, total: 1.00, percent: 10, secondsAgo: 45)
        expect(60, "a lower figure without a call in between")
        report(h, conversationH, total: 7.00, percent: 5, secondsAgo: 40)
        expect(60, "a lower figure in a session's first report")
        report(g, conversationG, total: 1.20, percent: 12, secondsAgo: 20)
        expect(12, "a lower figure after a call (a reset that kept resets_at)")
        report(h, conversationH, total: 7.10, percent: 11, secondsAgo: 30)
        expect(12, "a lower figure after an earlier call than the stored one's")
        report(g, UUID(), total: 3.00, percent: 2, secondsAgo: 10)
        expect(12, "a lower figure in a new conversation's first report")
        report(k, conversationK, total: 0.50, percent: 40, secondsAgo: 5)
        expect(40, "a higher figure")

        var changes = 0
        let watcher = monitor.objectWillChange.sink { changes += 1 }
        report(k, conversationK, total: 0.50, percent: 40, secondsAgo: 4, reset: fiveHourReset.addingTimeInterval(30))
        report(k, conversationK, total: 0.50, percent: 40, secondsAgo: 3)
        watcher.cancel()
        if changes != 0 { failures.append("repeating the same figure published \(changes) changes") }

        let legacy = URL(fileURLWithPath: directory).appendingPathComponent("usage-legacy.json")
        let stamp = ISO8601DateFormatter().string(from: fiveHourReset)
        let json = #"{"version": 1, "fiveHour": {"usedPercent": 44, "resetsAt": "\#(stamp)", "seen": "\#(stamp)"}, "days": {}}"#
        try? json.write(to: legacy, atomically: true, encoding: .utf8)
        if UsageMonitor(fileURL: legacy).fiveHour()?.usedPercent != 44 { failures.append("a usage.json with seen dates did not load") }
        return failures
    }

    /// ContextMonitor hands its readings to UsageMonitor: a report written to a watched folder for a Claude
    /// session that is never started reaches the usage figures.
    private func checkUsageFeed(directory: String) async -> [String] {
        let folder = URL(fileURLWithPath: directory).appendingPathComponent("usage-feed", isDirectory: true)
        let session = TerminalSession(spec: .claude(directory, remoteControl: false))
        let usage = UsageMonitor(fileURL: folder.appendingPathComponent("usage.json"))
        let monitor = ContextMonitor(directory: folder, sessions: { [session] },
                                     sessionsChanged: Empty().eraseToAnyPublisher(), usage: usage)
        monitor.start()
        defer {
            monitor.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let reset = Date().addingTimeInterval(3600)
        let data = usageReport(conversation: session.spec.claude?.sessionID ?? UUID(), prompt: "feed", total: 0.5,
                               model: ("claude-opus-5-5", "Opus 5.5"), fiveHour: (12, reset), sevenDay: nil, tokens: nil)
        try? data.write(to: folder.appendingPathComponent("\(session.id.uuidString.lowercased()).json"), options: .atomic)
        let reached = await waitUntil(3) { usage.fiveHour()?.usedPercent == 12 && usage.lastPrompt(for: session.id) != nil }
        return reached ? [] : ["a report in the context folder did not reach UsageMonitor"]
    }

    /// "Show usage in toolbar" removes the strip's toolbar item and puts it back.
    private func checkUsageSetting() async -> [String] {
        let settings = store.settings
        func shown() -> Bool {
            AppActions.mainWindow?.toolbar?.items.contains { $0.itemIdentifier.rawValue == "ConchUsage" } ?? false
        }
        guard settings.showUsageInToolbar, shown() else { return ["the usage strip is not in the toolbar by default"] }
        var failures: [String] = []
        settings.showUsageInToolbar = false
        if !(await waitUntil(2) { !shown() }) { failures.append("turning the setting off left the strip in the toolbar") }
        settings.showUsageInToolbar = true
        if !(await waitUntil(2) { shown() }) { failures.append("turning the setting on did not bring the strip back") }
        return failures
    }

    /// A statusline JSON shaped like Claude Code 2.1's, with resets_at in Unix seconds.
    private func usageReport(conversation: UUID, prompt: String?, total: Double, model: (String, String),
                             fiveHour: (Double, Date)?, sevenDay: (Double, Date)?, tokens: UsageTokens?) -> Data {
        var object: [String: Any] = [
            "session_id": conversation.uuidString.lowercased(),
            "model": ["id": model.0, "display_name": model.1],
            "cost": ["total_cost_usd": total, "total_api_duration_ms": 1000],
            "context_window": [
                "used_percentage": 10,
                "context_window_size": 200_000,
                "current_usage": [
                    "input_tokens": tokens?.input ?? 0,
                    "output_tokens": tokens?.output ?? 0,
                    "cache_creation_input_tokens": tokens?.cacheWrite ?? 0,
                    "cache_read_input_tokens": tokens?.cacheRead ?? 0,
                ],
            ],
        ]
        if let prompt { object["prompt_id"] = prompt }
        var limits: [String: Any] = [:]
        if let fiveHour { limits["five_hour"] = ["used_percentage": fiveHour.0, "resets_at": Int(fiveHour.1.timeIntervalSince1970)] }
        if let sevenDay { limits["seven_day"] = ["used_percentage": sevenDay.0, "resets_at": Int(sevenDay.1.timeIntervalSince1970)] }
        if !limits.isEmpty { object["rate_limits"] = limits }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
