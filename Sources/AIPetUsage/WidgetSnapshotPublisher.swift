import Foundation
import UsageCore
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Pushes dashboard chrome into `widget-snapshot.json` and reloads macOS WidgetKit timelines.
enum WidgetSnapshotPublisher {
    static func publish(dashboard: DashboardState,
                        limitStates: [ProviderLimitState],
                        enabledProviders: Set<String>,
                        colabCreditsEnabled: Bool = false,
                        colabSnapshot: ColabCreditsSnapshot? = nil) {
        let snap = WidgetSnapshotBuilder.build(
            dashboard: dashboard,
            limitStates: limitStates,
            enabledProviders: enabledProviders,
            colabCreditsEnabled: colabCreditsEnabled,
            colabSnapshot: colabSnapshot
        )
        WidgetSnapshotStore.write(snap)
#if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "ProviderUsageWidget")
        WidgetCenter.shared.reloadAllTimelines()
#endif
    }
}