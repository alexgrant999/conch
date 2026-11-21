import AppKit
import Combine
import Foundation

// Owner: usage builder (feature/usage-bars).

/// A plan limit as Conch last saw it. Older usage.json files also carry a "seen" date per limit, which decoding
/// ignores.
struct UsageLimit: Codable, Equatable {
    var usedPercent: Double
    var resetsAt: Date
}

/// The latest prompt in one Conch session.
struct PromptUsage: Equatable {
    /// API price of the prompt so far. nil while there is no baseline: the first prompt Conch saw in the session
    /// (unless nothing had been spent before it), or the prompt running when the total dropped or the
    /// conversation changed.
    var cost: Double?
    /// Points the 5-hour limit moved across the prompt, when both ends are known and in the same window.
    var fiveHourChange: Double?
    /// The latest API call.
    var tokens: UsageTokens?
}

struct ModelCost: Identifiable, Equatable {
    var id: String
    var name: String
    var cost: Double
}

enum UsagePeriod {
    /// The local calendar day.
    case today
    /// The current weekly limit window when its reset time is known, else the last 7 days.
    case week
}

/// Plan limits, the last prompt per session and cost by main model, all from the statusline reports ContextMonitor
/// applies. Claude Code reports one running total per session across every model it called (subagents, background
/// calls) and only the main model's id, so all of a session's spend counts under its main model. Only sessions
/// running in Conch are seen. Limits and daily totals persist to usage.json next to the state file, so they show
/// after a relaunch.
@MainActor
final class UsageMonitor: ObservableObject {
    static let shared = UsageMonitor(fileURL: defaultFileURL)

    /// Next to the statusline files, so CONCH_STATE_PATH isolates it too.
    static var defaultFileURL: URL { ContextStatusLine.supportDirectory.appendingPathComponent("usage.json") }
    static let keptDays = 35

    /// Reports from one window may disagree slightly on its reset time.
    private static let sameWindowTolerance: TimeInterval = 600
    private static let saveDelay: TimeInterval = 5

    let fileURL: URL

    @Published private(set) var storedFiveHour: UsageLimit?
    @Published private(set) var storedSevenDay: UsageLimit?
    @Published private(set) var prompts: [UUID: PromptUsage] = [:]
    /// Local day ("yyyy-MM-dd") to model id to that model's cost on the day.
    @Published private(set) var days: [String: [String: ModelTotal]] = [:]

    struct ModelTotal: Codable, Equatable {
        var name: String
        var cost: Double
    }

    private struct Track {
        var conversation: UUID?
        var promptID: String?
        var total: Double
        /// The total at the last report of the previous prompt.
        var baseline: Double?
        /// The account's 5-hour figure when the prompt started, and the latest one this session reported.
        var fiveHourAtStart: UsageLimit?
        var fiveHourLatest: RateLimitReading?
    }

    private var tracks: [UUID: Track] = [:]
    /// When the newest report that followed an API call was written, per limit. Reports are applied in file order,
    /// not time order, so a lower figure from an earlier call must not replace one from a later call.
    private var fiveHourCallReport: Date?
    private var sevenDayCallReport: Date?
    private var needsSave = false
    private var saveScheduled = false
    private var expiryGeneration = 0
    private var scheduledExpiry: Date?
    private var cancellables: Set<AnyCancellable> = []

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let file = Self.read(from: fileURL) {
            storedFiveHour = file.fiveHour
            storedSevenDay = file.sevenDay
            days = Self.pruned(file.days, now: Date())
        }
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.saveIfNeeded() } }
            .store(in: &cancellables)
        scheduleExpiryRefresh()
    }

    // MARK: - Reading

    /// nil when unknown or its window has reset.
    func fiveHour(at now: Date = Date()) -> UsageLimit? {
        storedFiveHour.flatMap { $0.resetsAt > now ? $0 : nil }
    }

    func sevenDay(at now: Date = Date()) -> UsageLimit? {
        storedSevenDay.flatMap { $0.resetsAt > now ? $0 : nil }
    }

    func lastPrompt(for session: UUID?) -> PromptUsage? {
        session.flatMap { prompts[$0] }
    }

    /// When the current weekly window started, or nil when its reset time is not known.
    func weekStart(at now: Date = Date()) -> Date? {
        sevenDay(at: now).map { $0.resetsAt.addingTimeInterval(-7 * 86_400) }
    }

    /// Most expensive first. The day the weekly window started counts in full, since totals are kept per day.
    func costs(for period: UsagePeriod, now: Date = Date()) -> [ModelCost] {
        let today = Self.dayKey(now)
        let first: String
        switch period {
        case .today:
            first = today
        case .week:
            first = Self.dayKey(weekStart(at: now) ?? Self.calendar.date(byAdding: .day, value: -6, to: now) ?? now)
        }
        var totals: [String: ModelCost] = [:]
        for key in days.keys.sorted() where key >= first && key <= today {
            for (id, model) in days[key] ?? [:] {
                var entry = totals[id] ?? ModelCost(id: id, name: model.name, cost: 0)
                entry.cost += model.cost
                entry.name = model.name
                totals[id] = entry
            }
        }
        return totals.values.sorted { $0.cost != $1.cost ? $0.cost > $1.cost : $0.name < $1.name }
    }

    // MARK: - Recording

    /// One report from a Conch session, written at `updated`.
    func record(_ reading: ContextReading, updated: Date, session: UUID) {
        let now = Date()
        // Before the limits merge, so a prompt's start figure is the one from before its first call.
        let afterCall = trackPrompt(reading, updated: updated, session: session, now: now)
        merge(reading.fiveHour, into: \.storedFiveHour, callReport: \.fiveHourCallReport, afterCall: afterCall,
              updated: updated, now: now)
        merge(reading.sevenDay, into: \.storedSevenDay, callReport: \.sevenDayCallReport, afterCall: afterCall,
              updated: updated, now: now)
    }

    /// The session closed.
    func forget(session: UUID) {
        tracks[session] = nil
        if prompts[session] != nil { prompts[session] = nil }
    }

    /// Writes usage.json now, dropping days older than `keptDays`.
    func saveNow() {
        needsSave = false
        let kept = Self.pruned(days, now: Date())
        if kept != days { days = kept }
        let file = UsageFile(fiveHour: storedFiveHour, sevenDay: storedSevenDay, days: kept)
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Conch: could not save usage to %@: %@", fileURL.path, error.localizedDescription)
        }
    }

    // MARK: - Private

    /// True when the session's total went up since its previous report: an API call finished in between, so the
    /// report's rate limits are that call's.
    private func trackPrompt(_ reading: ContextReading, updated: Date, session: UUID, now: Date) -> Bool {
        var afterCall = false
        var prompt = prompts[session] ?? PromptUsage()
        if let tokens = reading.tokens { prompt.tokens = tokens }
        if let total = reading.totalCost {
            let previous = tracks[session]
            var track: Track
            if var current = previous, !Self.restarted(current, reading, total: total) {
                if let id = reading.promptID, id != current.promptID {
                    current.promptID = id
                    current.baseline = current.total
                    current.fiveHourAtStart = fiveHour(at: now)
                    current.fiveHourLatest = nil
                }
                let spent = total - current.total
                if spent > 0 {
                    add(spent, model: reading.modelID, name: reading.modelName, on: updated)
                    afterCall = true
                }
                current.total = total
                track = current
            } else {
                // First report since launch, or /clear, /resume or a new conversation: the running prompt has no
                // baseline. A zero total means nothing was spent before a prompt that just started.
                let newPrompt = reading.promptID != nil && reading.promptID != previous?.promptID
                let fromZero = newPrompt && total == 0
                track = Track(conversation: reading.claudeSessionID, promptID: reading.promptID, total: total,
                              baseline: fromZero ? 0 : nil, fiveHourAtStart: fromZero ? fiveHour(at: now) : nil)
            }
            if let conversation = reading.claudeSessionID { track.conversation = conversation }
            if let limit = reading.fiveHour { track.fiveHourLatest = limit }
            tracks[session] = track

            prompt.cost = track.promptID == nil ? nil : track.baseline.map { max(total - $0, 0) }
            prompt.fiveHourChange = nil
            if prompt.cost != nil, let start = track.fiveHourAtStart, let end = track.fiveHourLatest, end.resetsAt > now,
               abs(end.resetsAt.timeIntervalSince(start.resetsAt)) <= Self.sameWindowTolerance {
                prompt.fiveHourChange = max(end.usedPercent - start.usedPercent, 0)
            }
        }
        if prompts[session] != prompt { prompts[session] = prompt }
        return afterCall
    }

    /// A drop in the total or a different conversation: deltas across it mean nothing.
    private static func restarted(_ track: Track, _ reading: ContextReading, total: Double) -> Bool {
        if let conversation = reading.claudeSessionID, let current = track.conversation, conversation != current {
            return true
        }
        return total < track.total - 0.000_001
    }

    /// Publishes and saves only when the stored figure really changes, since reports arrive every few seconds.
    private func merge(_ value: RateLimitReading?, into stored: ReferenceWritableKeyPath<UsageMonitor, UsageLimit?>,
                       callReport: ReferenceWritableKeyPath<UsageMonitor, Date?>, afterCall: Bool, updated: Date, now: Date) {
        guard let value else { return }
        let current = afterCall && (self[keyPath: callReport].map { updated >= $0 } ?? true)
        if current { self[keyPath: callReport] = updated }
        let merged = Self.merged(self[keyPath: stored], with: value, current: current, now: now)
        if merged != self[keyPath: stored] {
            self[keyPath: stored] = merged
            limitsChanged()
        }
    }

    /// Within one window use only goes up, so a lower figure usually comes from a session that has not made a
    /// request since, and is ignored. A `current` figure (from the newest report that followed an API call) is taken
    /// even when lower: a reset that kept resets_at, or a plan change. The same figure keeps the stored entry, so
    /// reports that disagree slightly on the reset time do not rewrite it. A later window replaces the stored one,
    /// an earlier one never does.
    private static func merged(_ stored: UsageLimit?, with value: RateLimitReading, current: Bool, now: Date) -> UsageLimit {
        let fresh = UsageLimit(usedPercent: value.usedPercent, resetsAt: value.resetsAt)
        guard let stored, stored.resetsAt > now else { return fresh }
        let gap = value.resetsAt.timeIntervalSince(stored.resetsAt)
        if gap > sameWindowTolerance { return fresh }
        if gap < -sameWindowTolerance { return stored }
        if value.usedPercent > stored.usedPercent || (current && value.usedPercent < stored.usedPercent) { return fresh }
        return stored
    }

    private func add(_ cost: Double, model: String?, name: String?, on date: Date) {
        let id = model ?? "unknown"
        let key = Self.dayKey(date)
        var day = days[key] ?? [:]
        var total = day[id] ?? ModelTotal(name: name ?? (model == nil ? "Unknown model" : id), cost: 0)
        total.cost += cost
        if let name { total.name = name }
        day[id] = total
        days[key] = day
        scheduleSave()
    }

    private func limitsChanged() {
        scheduleSave()
        scheduleExpiryRefresh()
    }

    private func scheduleSave() {
        needsSave = true
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.saveScheduled = false
                self?.saveIfNeeded()
            }
        }
    }

    private func saveIfNeeded() {
        if needsSave { saveNow() }
    }

    /// Redraws when a limit's window resets, so the toolbar stops showing a figure that no longer applies.
    /// Reports arrive several times a second, so only a different reset time schedules a new timer.
    private func scheduleExpiryRefresh() {
        let now = Date()
        let next = [storedFiveHour, storedSevenDay].compactMap { $0?.resetsAt }.filter { $0 > now }.min()
        guard next != scheduledExpiry else { return }
        scheduledExpiry = next
        expiryGeneration += 1
        guard let next else { return }
        let generation = expiryGeneration
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + next.timeIntervalSince(now) + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.expiryGeneration == generation else { return }
                self.scheduledExpiry = nil
                self.objectWillChange.send()
                self.scheduleExpiryRefresh()
            }
        }
    }

    private static func read(from url: URL) -> UsageFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(UsageFile.self, from: data)
        } catch {
            NSLog("Conch: could not read %@ (%@), starting usage afresh", url.path, error.localizedDescription)
            return nil
        }
    }

    private static func pruned(_ days: [String: [String: ModelTotal]], now: Date) -> [String: [String: ModelTotal]] {
        guard let oldest = calendar.date(byAdding: .day, value: -(keptDays - 1), to: now) else { return days }
        let first = dayKey(oldest)
        return days.filter { $0.key >= first }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    /// The local calendar day, as "yyyy-MM-dd" so keys sort by date.
    static func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

private struct UsageFile: Codable {
    var version = 1
    var fiveHour: UsageLimit?
    var sevenDay: UsageLimit?
    var days: [String: [String: UsageMonitor.ModelTotal]]
}
