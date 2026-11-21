import SwiftUI

// Owner: usage builder (feature/usage-bars). Shown at the trailing end of the main window's toolbar.

/// How much of the strip fits. MainWindowController sets it from the width of the terminal area.
enum UsageStripWidth {
    case full
    case noLastPrompt
    case barsOnly
}

/// What the strip needs from the window besides the monitor's figures.
@MainActor
final class UsageStripState: ObservableObject {
    @Published var activeSessionID: UUID?
    @Published var width: UsageStripWidth = .full
}

/// Plan limit bars and the active session's last prompt. Only known parts render. Clicking opens UsagePopover.
struct UsageStrip: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var state: UsageStripState

    @State private var showsPopover = false
    @State private var popoverClosed = Date.distantPast

    var body: some View {
        let fiveHour = monitor.fiveHour()
        let week = monitor.sevenDay()
        let lastCost = state.width == .full ? monitor.lastPrompt(for: state.activeSessionID)?.cost : nil
        let labelled = state.width != .barsOnly

        Button {
            // A transient popover closes on mouse down, so the same click would open it again on mouse up.
            if !showsPopover, Date().timeIntervalSince(popoverClosed) > 0.3 { showsPopover = true }
        } label: {
            HStack(spacing: 10) {
                if let fiveHour {
                    UsageLimitLabel(title: "5h", limit: fiveHour, labelled: labelled)
                        .help("5-hour limit: \(ContextLevel.percentText(fiveHour.usedPercent)) used, resets \(UsageFormat.time(fiveHour.resetsAt))")
                        .accessibilityLabel("5-hour limit \(ContextLevel.percentText(fiveHour.usedPercent)) used")
                }
                if let week {
                    UsageLimitLabel(title: "Week", limit: week, labelled: labelled)
                        .help("Weekly limit: \(ContextLevel.percentText(week.usedPercent)) used, resets \(UsageFormat.time(week.resetsAt))")
                        .accessibilityLabel("Weekly limit \(ContextLevel.percentText(week.usedPercent)) used")
                }
                if let lastCost {
                    Text("Last \(UsageFormat.cost(lastCost))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Last prompt in this session: \(UsageFormat.cost(lastCost)) at API prices")
                }
                if fiveHour == nil && week == nil && lastCost == nil {
                    // Keeps the popover reachable for the costs by main model while no limit has been reported.
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .help("Claude usage")
                        .accessibilityLabel("Claude usage")
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            UsagePopover(monitor: monitor, state: state)
        }
        .onChange(of: showsPopover) { _, shown in
            if !shown { popoverClosed = Date() }
        }
    }
}

/// "5h ▬▬▭ 42%". Without the label only the bar shows, and the tooltip carries the figure.
struct UsageLimitLabel: View {
    let title: String
    let limit: UsageLimit
    let labelled: Bool

    var body: some View {
        let level = ContextLevel(limit.usedPercent)
        HStack(spacing: 5) {
            if labelled {
                Text(title)
                    .foregroundStyle(.secondary)
            }
            UsageBar(fraction: limit.usedPercent / 100, tint: level.color)
                .frame(width: 36, height: 5)
            if labelled {
                Text(ContextLevel.percentText(limit.usedPercent))
                    .fontWeight(level == .normal ? .regular : .semibold)
                    .foregroundStyle(level.color)
            }
        }
        .font(.system(size: 11).monospacedDigit())
    }
}

/// A capsule progress bar. Any fill above zero shows at least as a dot.
struct UsageBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if clamped > 0 {
                    Capsule().fill(tint)
                        .frame(width: max(proxy.size.width * clamped, proxy.size.height))
                }
            }
        }
    }
}

/// Number and time formats shared by the strip and the popover.
@MainActor
enum UsageFormat {
    /// "$0.42", "<$0.01" for a fraction of a cent.
    static func cost(_ dollars: Double) -> String {
        if dollars > 0 && dollars < 0.005 { return "<$0.01" }
        return String(format: "$%.2f", dollars)
    }

    /// "3:10 pm" today, "Mon 9:00 am" later this week, "Nov 16, 9:00 am" further out or on an earlier day (so a
    /// window's start never reads like its reset). Local time.
    static func time(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDate(date, inSameDayAs: now) { return timeOnly.string(from: date) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 7
        return (days > 0 && days < 7 ? weekdayAndTime : dateAndTime).string(from: date)
    }

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }

    private static let timeOnly = formatter("jmm")
    private static let weekdayAndTime = formatter("EEEjmm")
    private static let dateAndTime = formatter("MMMdjmm")
}
