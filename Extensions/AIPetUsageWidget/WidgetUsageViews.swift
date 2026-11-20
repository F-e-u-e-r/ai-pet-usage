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
        .description("Codex, Claude, Antigravity, Grok, OpenCode, and Cursor limits from AI Pet Usage.")
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
    var compact = false
    var showLegend = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("🐾 AI Usage")
                .font(compact ? .caption.weight(.semibold) : .headline)
                .lineLimit(1)
                .fixedSize()
            if showLegend {
                Text("5h · wk")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 4)
            if !compact, let cost = snapshot.todayCostUSD, snapshot.isFromSameDay(as: now) {
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
        VStack(alignment: .leading, spacing: 3) {
            WidgetHeader(snapshot: entry.snapshot, now: entry.date, compact: true, showLegend: true)
            if !live || entry.snapshot.rows.isEmpty {
                Text("Open AI Pet Usage to refresh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FittingRows(rows: entry.snapshot.rows, spacing: 1) { row in
                    WidgetRowCompact(row: row, now: entry.date)
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
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(snapshot: entry.snapshot, now: entry.date, showLegend: true)
            if !live || entry.snapshot.rows.isEmpty {
                Text(live ? "No limit data yet — keep the menu-bar app running."
                           : "Open AI Pet Usage once, then remove and re-add this widget.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let rows = entry.snapshot.rows
                let half = (rows.count + 1) / 2
                HStack(alignment: .top, spacing: 12) {
                    FittingRows(rows: Array(rows.prefix(half)), spacing: 3) { row in
                        WidgetRowLine(row: row, showBars: false, now: entry.date)
                    }
                    FittingRows(rows: Array(rows.dropFirst(half)), spacing: 3) { row in
                        WidgetRowLine(row: row, showBars: false, now: entry.date)
                    }
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
            WidgetHeader(snapshot: entry.snapshot, now: entry.date, showLegend: true)
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
                FittingRows(rows: entry.snapshot.rows, spacing: 7) { row in
                    WidgetRowLine(row: row, showBars: true, now: entry.date)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Shows as many rows as fit vertically; if some are cut, the last line says "+N more"
/// instead of silently clipping.
private struct FittingRows<Row: View>: View {
    let rows: [WidgetSnapshotRow]
    let spacing: CGFloat
    @ViewBuilder let content: (WidgetSnapshotRow) -> Row

    var body: some View {
        ViewThatFits(in: .vertical) {
            ForEach(Array(stride(from: rows.count, through: 1, by: -1)), id: \.self) { n in
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(rows.prefix(n)) { row in content(row) }
                    if n < rows.count {
                        Text("+\(rows.count - n) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct WidgetRowCompact: View {
    let row: WidgetSnapshotRow
    let now: Date

    var body: some View {
        HStack(spacing: 4) {
            ProviderDot(color: row.dotColor, size: 6)
            Text(row.shortName)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 2)
            usageValues
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(usageAccessibilityLabel)
        }
    }

    @ViewBuilder
    private var usageValues: some View {
        if row.idle {
            Text("idle")
        } else if row.isWeeklyStale {
            // One Text (not an HStack) so layout and the a11y label match the live case.
            Text("\(fiveHourText)/") + Text(weeklyText).foregroundColor(.primary.opacity(0.55))
        } else {
            Text("\(fiveHourText)/\(weeklyText)")
        }
    }

    private var fiveHourText: String {
        row.fiveHourPercent.map { "\(min(100, max(0, $0)))%" } ?? "—"
    }

    private var weeklyText: String {
        row.weeklyPercent.map { "\(min(100, max(0, $0)))%" } ?? "—"
    }

    private var usageAccessibilityLabel: String {
        if row.idle { return "idle" }
        let a = row.fiveHourPercent.map { "\(min(100, max(0, $0))) percent" } ?? "no data"
        let b = row.weeklyPercent.map { "\(min(100, max(0, $0))) percent" } ?? "no data"
        let age = row.weeklyStaleLabel(now: now).map { " (\($0))" } ?? ""
        return "5 hour \(a), week \(b)\(age)"
    }
}

/// One line per provider: dot · name · 5h · wk. `showBars` adds meter bars (large widget).
private struct WidgetRowLine: View {
    let row: WidgetSnapshotRow
    let showBars: Bool
    let now: Date

    private var weeklyStaleLabel: String? { row.weeklyStaleLabel(now: now) }

    var body: some View {
        HStack(spacing: 6) {
            ProviderDot(color: row.dotColor, size: 7)
            Text(row.shortName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: showBars ? 96 : nil, alignment: .leading)
            if !showBars { Spacer(minLength: 2) }
            if row.idle {
                Text("idle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if showBars { Spacer(minLength: 0) }
            } else if showBars {
                MeterBar(percent: row.fiveHourPercent, window: "5 hour")
                MeterBar(
                    percent: row.weeklyPercent,
                    window: "week",
                    weeklyStale: row.isWeeklyStale,
                    weeklyStaleLabel: weeklyStaleLabel
                )
            } else {
                PercentText(percent: row.fiveHourPercent, window: "5 hour")
                PercentText(
                    percent: row.weeklyPercent,
                    window: "week",
                    weeklyStale: row.isWeeklyStale,
                    weeklyStaleLabel: weeklyStaleLabel
                )
            }
        }
    }
}

private struct PercentText: View {
    let percent: Int?
    let window: String
    var weeklyStale = false
    var weeklyStaleLabel: String? = nil

    private var displayedPercent: Int? {
        percent.map { min(100, max(0, $0)) }
    }

    var body: some View {
        Text(displayedPercent.map { "\($0)%" } ?? "—")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(displayedPercent.map(percentColor) ?? .secondary)
            .lineLimit(1)
            .fixedSize()
            .frame(width: 30, alignment: .trailing)
            .opacity(weeklyStale ? 0.55 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let base = displayedPercent.map { "\(window) \($0) percent" } ?? "\(window) no data"
        guard weeklyStale, let weeklyStaleLabel else { return base }
        return base + " (\(weeklyStaleLabel))"
    }
}

private func percentColor(_ p: Int) -> Color {
    if p >= 95 { return .red }
    if p >= 80 { return .orange }
    return .primary
}

private struct MeterBar: View {
    let percent: Int?
    let window: String
    var weeklyStale = false
    var weeklyStaleLabel: String? = nil

    private var displayedPercent: Int? {
        percent.map { min(100, max(0, $0)) }
    }

    var body: some View {
        HStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if let p = displayedPercent {
                        Capsule()
                            .fill(barColor(p))
                            .frame(width: geo.size.width * CGFloat(p) / 100)
                    }
                }
            }
            .frame(height: 5)
            Text(displayedPercent.map { "\($0)%" } ?? "—")
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                .frame(width: 28, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .opacity(weeklyStale ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let base = displayedPercent.map { "\(window) \($0) percent" } ?? "\(window) no data"
        guard weeklyStale, let weeklyStaleLabel else { return base }
        return base + " (\(weeklyStaleLabel))"
    }

    private func barColor(_ p: Int) -> Color {
        if p >= 95 { return .red }
        if p >= 80 { return .orange }
        return .accentColor
    }
}

private struct ProviderDot: View {
    let color: UInt32
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Color(rgb: color))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.5))
            .frame(width: size, height: size)
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
