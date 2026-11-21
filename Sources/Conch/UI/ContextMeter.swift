import SwiftUI

// Owner: context builder (feature/context). Shown in each sidebar row, before the close button.

struct ContextMeter: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if session.spec.kind == .claude, let usage = session.context {
            let level = ContextLevel(usage.usedPercent)
            Text(ContextLevel.percentText(usage.usedPercent))
                .font(.system(size: 10, weight: level == .normal ? .regular : .semibold).monospacedDigit())
                .foregroundStyle(level.color)
                .help(ContextLevel.tooltip(usage))
                .accessibilityLabel("Context \(ContextLevel.percentText(usage.usedPercent)) used")
        }
    }
}

/// How full a Claude session's context window is, and what to do about it.
enum ContextLevel {
    case normal
    case filling
    case full

    init(_ usedPercent: Double) {
        switch usedPercent {
        case 80...: self = .full
        case 60...: self = .filling
        default: self = .normal
        }
    }

    var color: Color {
        switch self {
        case .normal: return .secondary
        case .filling: return .orange
        case .full: return .red
        }
    }

    var advice: String? {
        switch self {
        case .normal: return nil
        case .filling: return "Compact when this task is done. Clear instead if the next task is unrelated."
        case .full: return "Compact now, or clear if you are switching tasks."
        }
    }

    /// Whole percent, rounded down so the number never reads higher than the colour band it is in.
    static func percentText(_ usedPercent: Double) -> String {
        "\(Int(usedPercent))%"
    }

    static func tooltip(_ usage: ContextUsage) -> String {
        var lines = ["Context: \(String(format: "%.1f", usage.usedPercent))% used"
            + (usage.windowTokens.map { " of \(tokenCount($0)) tokens" } ?? "")]
        if let advice = ContextLevel(usage.usedPercent).advice {
            lines.append(advice)
            lines.append("Claude Code also compacts on its own near the limit.")
        }
        return lines.joined(separator: "\n")
    }

    /// 1000000 gives "1M", 200000 gives "200K".
    static func tokenCount(_ tokens: Int) -> String {
        if tokens >= 1_000_000, tokens % 100_000 == 0 {
            let millions = Double(tokens) / 1_000_000
            return millions == millions.rounded() ? "\(Int(millions))M" : String(format: "%.1fM", millions)
        }
        if tokens >= 1_000 { return "\(tokens / 1_000)K" }
        return "\(tokens)"
    }
}
