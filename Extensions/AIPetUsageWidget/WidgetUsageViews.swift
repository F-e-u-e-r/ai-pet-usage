import SwiftUI
import WidgetKit
import UsageCore

struct ProviderUsageWidget: Widget {
    let kind = "ProviderUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageTimelineProvider()) { entry in
            WidgetUsageRootView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("AI Usage")
        .description("Codex, Claude, Antigravity, Grok, and OpenCode limits from AI Pet Usage.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct WidgetUsageRootView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            WidgetSmallView(entry: entry)
        case .systemMedium:
            WidgetMediumView(entry: entry)
        default:
            WidgetLargeView(entry: entry)
        }
    }
}

private struct WidgetHeader: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("🐾 AI Usage")
                .font(.headline)
            Spacer(minLength: 4)
            if let cost = snapshot.todayCostUSD, snapshot.isFromSameDay(as: now) {
                Text(costLine(cost))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func costLine(_ usd: Double) -> String {
        let est = snapshot.todayCostIsEstimated ? "~" : ""
        return "\(est)$\(String(format: "%.2f", usd))"
    }
}

private struct WidgetSmallView: View {
    let entry: UsageEntry

  private var live: Bool { WidgetSnapshotStore.isPopulated(entry.snapshot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(snapshot: entry.snapshot, now: entry.date)
            if !live || entry.snapshot.rows.isEmpty {
                Text("Open AI Pet Usage to refresh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entry.snapshot.rows.prefix(3)) { row in
                    WidgetRowCompact(row: row)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct WidgetMediumView: View {
    let entry: UsageEntry

    private var live: Bool { WidgetSnapshotStore.isPopulated(entry.snapshot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(snapshot: entry.snapshot, now: entry.date)
            if !live || entry.snapshot.rows.isEmpty {
                Text(live ? "No limit data yet — keep the menu-bar app running."
                           : "Open AI Pet Usage once, then remove and re-add this widget.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entry.snapshot.rows.prefix(5)) { row in
                    WidgetRowDetailed(row: row)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct WidgetLargeView: View {
    let entry: UsageEntry

    private var live: Bool { WidgetSnapshotStore.isPopulated(entry.snapshot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(snapshot: entry.snapshot, now: entry.date)
            if live, entry.snapshot.isFromSameDay(as: entry.date) {
                Text("\(entry.snapshot.todayTokens.formatted()) tokens today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Open AI Pet Usage to sync usage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            if entry.snapshot.rows.isEmpty {
                Text("No providers with limit data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entry.snapshot.rows) { row in
                    WidgetRowDetailed(row: row)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct WidgetRowCompact: View {
    let row: WidgetSnapshotRow

    var body: some View {
        HStack(spacing: 6) {
            ProviderDot(color: row.dotColor)
            Text(row.code)
                .font(.caption.weight(.semibold))
                .frame(width: 22, alignment: .leading)
            Text(usageText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }

    private var usageText: String {
        if row.idle { return "idle" }
        let a = row.fiveHourPercent.map { "\($0)%" } ?? "—"
        let b = row.weeklyPercent.map { "\($0)%" } ?? "—"
        return "\(a)/\(b)"
    }
}

private struct WidgetRowDetailed: View {
    let row: WidgetSnapshotRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProviderDot(color: row.dotColor)
                Text(row.shortName)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(row.code)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if row.idle {
                Text("idle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    MeterBar(label: "5h", percent: row.fiveHourPercent)
                    MeterBar(label: "wk", percent: row.weeklyPercent)
                }
            }
        }
    }
}

private struct MeterBar: View {
    let label: String
    let percent: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if let p = percent {
                        Capsule()
                            .fill(barColor(p))
                            .frame(width: geo.size.width * CGFloat(min(100, max(0, p))) / 100)
                    }
                }
            }
            .frame(height: 6)
            Text(percent.map { "\($0)%" } ?? "—")
                .font(.caption2.monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }

    private func barColor(_ p: Int) -> Color {
        if p >= 95 { return .red }
        if p >= 80 { return .orange }
        return .accentColor
    }
}

private struct ProviderDot: View {
    let color: UInt32

    var body: some View {
        Circle()
            .fill(Color(rgb: color))
            .frame(width: 8, height: 8)
    }
}

private extension Color {
    init(rgb: UInt32) {
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}