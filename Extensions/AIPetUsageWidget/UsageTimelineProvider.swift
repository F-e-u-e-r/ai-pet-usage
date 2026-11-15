import Foundation
import WidgetKit
import UsageCore

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: Date(), snapshot: WidgetSnapshotStore.read(from: .widgetExtension) ?? .preview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snap = WidgetSnapshotStore.read(from: .widgetExtension) ?? .empty
        let entry = UsageEntry(date: Date(), snapshot: snap)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

extension WidgetSnapshot {
    static let preview = WidgetSnapshot(
        generatedAt: Date(),
        todayTokens: 128_400,
        todayCostUSD: 2.14,
        todayCostIsEstimated: true,
        rows: [
            WidgetSnapshotRow(providerId: "codex", shortName: "Codex", code: "CX", dotColor: 0x3B82F6,
                              fiveHourPercent: 42, weeklyPercent: 61, idle: false),
            WidgetSnapshotRow(providerId: "grok-code", shortName: "Grok", code: "GK", dotColor: 0x2E3138,
                              fiveHourPercent: 18, weeklyPercent: nil, idle: false),
            WidgetSnapshotRow(providerId: "opencode", shortName: "OpenCode", code: "OC", dotColor: 0xCA8A04,
                              fiveHourPercent: nil, weeklyPercent: 33, idle: false),
        ]
    )
}