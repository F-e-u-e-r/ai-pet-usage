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
        let snap = WidgetSnapshotStore.read(from: .widgetExtension) ?? .empty
        completion(UsageEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snap = WidgetSnapshotStore.read(from: .widgetExtension) ?? .empty
        let now = Date()
        var entries = [UsageEntry(date: now, snapshot: snap)]
        // Re-render at midnight too: the view hides "today" totals from an earlier day by `entry.date`.
        if let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0),
                                                     matchingPolicy: .nextTime) {
            entries.append(UsageEntry(date: midnight, snapshot: snap))
        }
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(900)
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}