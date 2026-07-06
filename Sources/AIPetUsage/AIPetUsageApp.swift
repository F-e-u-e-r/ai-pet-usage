import SwiftUI
import AppKit
import UsageCore
import PetCore

@main
struct AIPetUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        AppDelegate.sharedModel = model
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }

        Window("AI Pet Usage", id: "dashboard") {
            DashboardRoot()
                .environment(model)
        }
        .defaultSize(width: 920, height: 660)

        Settings {
            SettingsRoot()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var sharedModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 選單列常駐工具:不佔 Dock、不搶焦點。
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            AppDelegate.sharedModel?.start()
        }
    }
}

// MARK: - 選單列

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(model.menuBarTitle)
            .monospacedDigit()
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Provider 摘要(不可點,只呈現)
        ForEach(model.dashboard.snapshots) { snap in
            let five = snap.sessionUsagePercent.map { String(format: "5h %.0f%%", $0) } ?? "5h —"
            let week = snap.weeklyUsagePercent.map { String(format: "wk %.0f%%", $0) } ?? "wk —"
            let reset = snap.resetAt.map { " · resets \(countdown(to: $0))" } ?? ""
            Text("\(snap.displayName): \(five) · \(week)\(reset)")
        }
        if model.dashboard.snapshots.isEmpty {
            Text("No providers enabled")
        }

        Divider()

        Button("Open Dashboard") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "dashboard")
        }
        .keyboardShortcut("d")

        Button(model.refreshing ? "Refreshing…" : "Refresh Now") {
            Task { await model.refreshNow() }
        }
        .disabled(model.refreshing)
        .keyboardShortcut("r")

        Button("Export Today's Report…") {
            model.exportToday()
        }

        Divider()

        if model.settings.appMode == .full {
            Menu("Feed \(model.settings.species.displayName)  (treats: \(model.treatsAvailable))") {
                ForEach(FoodItem.starterFoods) { food in
                    Button("\(food.emoji) \(food.name)\(food.treatCost > 0 ? " — \(food.treatCost)🎟" : " (free)")") {
                        _ = model.feed(food)
                    }
                }
                Divider()
                Text("Hunger \(Int(model.petState.hunger))% · Lv.\(model.petState.level)")
            }

            Toggle("Show Pet", isOn: Binding(
                get: { model.settings.petVisible },
                set: { v in model.updateSettings { $0.petVisible = v } }
            ))
        }

        Toggle("Quiet Mode", isOn: Binding(
            get: { model.settings.quietMode },
            set: { v in model.updateSettings { $0.quietMode = v } }
        ))

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Quit AI Pet Usage") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
