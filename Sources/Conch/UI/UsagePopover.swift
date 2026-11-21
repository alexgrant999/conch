import SwiftUI

// Owner: usage builder (feature/usage-bars). Opened by clicking UsageStrip.

/// Plan limits, cost by main model for today and this week, and the active session's last prompt.
struct UsagePopover: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var state: UsageStripState

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 14) {
            section("Plan limits") {
                limitRow("5-hour", monitor.fiveHour(at: now), now: now)
                limitRow("Weekly", monitor.sevenDay(at: now), now: now)
            }
            section("Today") {
                modelRows(monitor.costs(for: .today, now: now))
            }
            section("This week", note: monitor.weekStart(at: now).map { "since \(UsageFormat.time($0, now: now))" } ?? "last 7 days") {
                modelRows(monitor.costs(for: .week, now: now))
            }
            section("Last prompt in this session") {
                lastPrompt(monitor.lastPrompt(for: state.activeSessionID))
            }
            Divider()
            Text("Costs are what Claude Code reports at API prices, for sessions running in Conch, by each session's main model. Subagent and background spend counts under the session's main model. Per-model plan limits are not reported to Conch.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func section<Content: View>(_ title: String, note: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            content()
        }
    }

    @ViewBuilder
    private func limitRow(_ title: String, _ limit: UsageLimit?, now: Date) -> some View {
        if let limit {
            let level = ContextLevel(limit.usedPercent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .frame(width: 52, alignment: .leading)
                    UsageBar(fraction: limit.usedPercent / 100, tint: level.color)
                        .frame(height: 6)
                    Text(ContextLevel.percentText(limit.usedPercent))
                        .fontWeight(level == .normal ? .regular : .semibold)
                        .foregroundStyle(level.color)
                        .frame(width: 38, alignment: .trailing)
                }
                .font(.system(size: 12).monospacedDigit())
                Text("Resets \(UsageFormat.time(limit.resetsAt, now: now))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 60)
            }
        } else {
            HStack(spacing: 8) {
                Text(title)
                    .frame(width: 52, alignment: .leading)
                Text("Not reported yet")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
        }
    }

    @ViewBuilder
    private func modelRows(_ costs: [ModelCost]) -> some View {
        let total = costs.reduce(0) { $0 + $1.cost }
        if costs.isEmpty || total <= 0 {
            Text("Nothing recorded yet")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        } else {
            ForEach(costs) { model in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(model.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(UsageFormat.cost(model.cost))
                            .monospacedDigit()
                    }
                    .font(.system(size: 12))
                    UsageBar(fraction: model.cost / total, tint: .secondary)
                        .frame(height: 4)
                }
            }
        }
    }

    @ViewBuilder
    private func lastPrompt(_ prompt: PromptUsage?) -> some View {
        if let prompt {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    if let cost = prompt.cost {
                        Text(UsageFormat.cost(cost))
                            .font(.system(size: 12).monospacedDigit())
                    } else {
                        Text("Cost shows from the next prompt")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    if let change = prompt.fiveHourChange {
                        Text(change < 1 ? "under 1% of the 5-hour limit" : "\(Int(change.rounded()))% of the 5-hour limit")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let tokens = prompt.tokens {
                    Text("Latest call")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        GridRow {
                            tokenCell("New input", tokens.input)
                            tokenCell("Cache read", tokens.cacheRead)
                        }
                        GridRow {
                            tokenCell("Cache write", tokens.cacheWrite)
                            tokenCell("Output", tokens.output)
                        }
                    }
                }
            }
        } else {
            Text("Nothing reported for this session yet")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    private func tokenCell(_ title: String, _ count: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(ContextLevel.tokenCount(count))
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .frame(width: 130, alignment: .leading)
    }
}
