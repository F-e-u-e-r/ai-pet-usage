import SwiftUI
import AppKit
import UsageCore
import PetCore

// MenuBarExtra(.window)自訂面板(UIUX spec §7–§9):
//   [狀態 header:寵物 + 各 provider 全名列 + 警示摘要]
//   Open Dashboard ⌘D / Refresh ⌘R / Export
//   Give Treat (N) ▸ / Show Pet / Snooze Alerts ▸
//   Settings… ⌘, / Quit ⌘Q
// header 與選單列共用同一套 severity 上色規則:選單列標紅的 provider,
// 面板裡同一個數字也一定標紅(視覺連續性)。

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var feedExpanded = false
    @State private var snoozeExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            PanelHeader()
            PanelDivider()

            PanelActionRow(title: "Open Dashboard", trailing: "⌘D", shortcut: "d") {
                dismiss()
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "dashboard")
            }
            PanelActionRow(title: model.refreshing ? "Refreshing…" : "Refresh Now",
                           trailing: "⌘R", shortcut: "r", disabled: model.refreshing) {
                Task { await model.refreshNow() }
            }
            PanelActionRow(title: "Export Today's Report…") {
                dismiss()
                model.exportToday()
            }

            if model.settings.appMode == .full {
                PanelDivider()
                GiveTreatSection(expanded: $feedExpanded)
                PanelToggleRow(title: "Show Pet", isOn: model.settings.petVisible) {
                    model.updateSettings { $0.petVisible.toggle() }
                }
            }

            PanelDivider()
            SnoozeSection(expanded: $snoozeExpanded)

            PanelDivider()
            PanelActionRow(title: "Settings…", trailing: "⌘,", shortcut: ",") {
                dismiss()
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            PanelActionRow(title: "Quit AI Pet Usage", trailing: "⌘Q", shortcut: "q") {
                NSApp.terminate(nil)
            }
        }
        .padding(6)
        .frame(width: 320)
    }
}

// MARK: - Header

/// 面板狀態 header:不是灰字選單項,而是全彩自訂視圖(spec §8)。
private struct PanelHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(model.menuBarPetEmoji).font(.system(size: 15))
                Text(model.settings.appMode == .full ? model.settings.resolvedSpecies.displayName : "AI Pet Usage")
                    .font(.headline)
                Spacer()
                if model.settings.appMode == .full {
                    Text("Lv.\(model.petState.level)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // 倒數需要走時鐘;面板開著時每 30s 重算一次即可
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.orderedLimitStates) { state in
                        ProviderStatusRow(state: state, now: context.date)
                    }
                    if model.orderedLimitStates.isEmpty {
                        Text("No providers enabled")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let alert = model.alertSummary {
                        Label(alert.text, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(alert.isDanger ? Color.red : Color.orange)
                            .padding(.top, 1)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

/// 一列 provider 狀態:● 全名 5h% wk% resets Xm(百分比依 severity 上色)。
private struct ProviderStatusRow: View {
    @Environment(AppModel.self) private var model
    let state: ProviderLimitState
    let now: Date

    var body: some View {
        let brand = ProviderBrands.brand(for: state.providerId,
                                         displayName: model.providerName(state.providerId))
        HStack(spacing: 6) {
            ProviderDot(brand: brand, size: 8)
            Text(brand.displayName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            windowText("5h", state.fiveHour.usedPercent)
            windowText("wk", state.weekly.usedPercent)
            Text(resetLabel)
                .font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 66, alignment: .trailing)
        }
        .help("\(brand.displayName) (\(brand.code)) — official/estimated 5h & weekly usage")
    }

    private func windowText(_ label: String, _ percent: Double?) -> some View {
        let severity = UsageSeverity.of(percent: percent,
                                        warn: model.settings.core.warnThresholdPercent,
                                        danger: model.settings.core.dangerThresholdPercent)
        return HStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.callout.weight(.semibold)).monospacedDigit()
                .foregroundStyle(severityColor(severity) ?? .primary)
        }
    }

    private var resetLabel: String {
        if let reset = state.fiveHour.resetAt { return "resets \(countdown(to: reset, now: now))" }
        if let reset = state.weekly.resetAt { return "wk resets \(countdown(to: reset, now: now))" }
        return ""
    }
}

// MARK: - 列元件

private struct PanelDivider: View {
    var body: some View {
        Divider().padding(.vertical, 3).padding(.horizontal, 4)
    }
}

/// 仿選單列的可點列:hover 高亮、右側 ⌘ 提示或成本標示。
private struct PanelActionRow: View {
    let title: String
    var trailing: String? = nil
    var shortcut: KeyEquivalent? = nil
    var disabled = false
    var indent: CGFloat = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(disabled ? Color.secondary : Color.primary)
                Spacer()
                if let trailing {
                    Text(trailing).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .padding(.leading, 8 + indent)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(hovering && !disabled ? Color.primary.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
        .modifier(OptionalShortcut(key: shortcut))
    }
}

private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?
    func body(content: Content) -> some View {
        if let key { content.keyboardShortcut(key) } else { content }
    }
}

/// 勾選列(Show Pet)。
private struct PanelToggleRow: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(isOn ? 1 : 0)
                    .frame(width: 12)
                Text(title).foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
    }
}

// MARK: - Give Treat

/// 「Give Treat (N)」展開段:物種化食物名 + 成本與效果標示 + Fullness 摘要。
private struct GiveTreatSection: View {
    @Environment(AppModel.self) private var model
    @Binding var expanded: Bool

    var body: some View {
        PanelActionRow(title: "Give Treat (\(model.treatsAvailable))",
                       trailing: expanded ? "▾" : "▸") {
            expanded.toggle()
        }
        if expanded {
            ForEach(FoodItem.foods(for: model.settings.resolvedSpecies)) { food in
                PanelActionRow(title: "\(food.emoji) \(food.name)",
                               trailing: costLabel(food), indent: 14) {
                    _ = model.feed(food)
                }
            }
            Text("Fullness \(Int(model.petState.hunger))% · Lv.\(model.petState.level) · Treats: \(model.treatsAvailable)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
                .padding(.vertical, 2)
        }
    }

    private func costLabel(_ food: FoodItem) -> String {
        let cost = food.treatCost == 0 ? "free" : "\(food.treatCost)🎟"
        return "\(cost) · +\(Int(food.satiety))"
    }
}

// MARK: - Snooze Alerts

/// 「Snooze Alerts」展開段:暫停通知一段時間,追蹤照常(spec §10 wording)。
private struct SnoozeSection: View {
    @Environment(AppModel.self) private var model
    @Binding var expanded: Bool

    var body: some View {
        PanelActionRow(title: "Snooze Alerts",
                       trailing: trailingLabel) {
            expanded.toggle()
        }
        if expanded {
            if model.activeSnoozeUntil != nil {
                PanelActionRow(title: "Turn Off Snooze", indent: 14) {
                    model.cancelSnooze()
                    expanded = false
                }
            }
            PanelActionRow(title: "30 minutes", indent: 14) { snooze(30 * 60) }
            PanelActionRow(title: "1 hour", indent: 14) { snooze(3600) }
            PanelActionRow(title: "2 hours", indent: 14) { snooze(2 * 3600) }
            PanelActionRow(title: "Until tomorrow", indent: 14) {
                model.snoozeAlertsUntilTomorrow()
                expanded = false
            }
            Text("Notifications pause; tracking continues.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
                .padding(.vertical, 2)
        }
    }

    private var trailingLabel: String {
        if let until = model.activeSnoozeUntil {
            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            return "until \(df.string(from: until)) ▾"
        }
        return expanded ? "▾" : "▸"
    }

    private func snooze(_ seconds: TimeInterval) {
        model.snoozeAlerts(for: seconds)
        expanded = false
    }
}
