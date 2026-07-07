import Foundation
import AppKit
import Observation
import UsageCore
import PetCore

/// 專案頁的時間範圍選擇(可逆、可直接跳轉——規格明令禁止單向循環)。
enum RangePreset: String, CaseIterable, Identifiable {
    case today, yesterday, last7Days, thisWeek, lastWeek, allTime, custom
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .last7Days: return "Last 7 days"
        case .thisWeek: return "This week"
        case .lastWeek: return "Last week"
        case .allTime: return "All time"
        case .custom: return "Custom"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    // 對 UI 暴露的狀態
    private(set) var dashboard: DashboardState = .empty
    private(set) var settings: AppSettings
    private(set) var petState: PetStateData
    private(set) var mood = MoodEngine.Result(mood: .idle, animationSpeed: 1, summary: "starting…")
    private(set) var treatsAvailable = 0
    private(set) var refreshing = false
    private(set) var reindexing = false

    // Projects 頁狀態
    var rangePreset: RangePreset = .today
    var customStart: Date = Calendar.current.startOfDay(for: Date().addingTimeInterval(-6 * 86400))
    var customEnd: Date = Date()
    private(set) var projectPage: ProjectPageData?

    // 內部
    let coordinator: UsageCoordinator
    private let settingsStore: SettingsStore
    private let dataDir: URL
    /// monitor-only(低 RAM)模式下完全不建立;只在 full 模式第一次用到時載入。
    private var feeding: FeedingEngine?
    private var petPanel: PetPanelController?
    private var refreshLoop: Task<Void, Never>?
    private var activeMinutesToday: Double = 0
    /// 設定推送到 coordinator 的序列化尾巴:每次推送先 await 前一個,保證按呼叫順序落地
    /// (fire-and-forget Task 不保證順序,舊 core 可能覆蓋新 core)。
    private var settingsPushTask: Task<Void, Never>?

    init() {
        dataDir = AppPaths.dataDirectory()
        settingsStore = SettingsStore(dataDir: dataDir)
        settings = settingsStore.settings
        coordinator = UsageCoordinator(dataDir: dataDir, settings: settingsStore.settings.core)
        petState = PetStateData()
    }

    /// full 模式限定的餵食引擎存取(延遲建立並載回持久化狀態)。
    private var feedingEngine: FeedingEngine {
        if let feeding { return feeding }
        let engine = FeedingEngine(stateURL: dataDir.appendingPathComponent("pet-state.json"))
        feeding = engine
        petState = engine.state
        return engine
    }

    // MARK: - 生命週期

    func start() {
        if LaunchAtLogin.available {
            let enabled = LaunchAtLogin.isEnabled
            if settings.launchAtLogin != enabled {
                updateSettings { $0.launchAtLogin = enabled }
            }
        }
        if settings.notificationsEnabled { Notifier.requestAuthorization() }
        applyModeSideEffects()
        observeAppearanceChanges()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                let interval = self?.settings.refreshIntervalSeconds ?? 45
                try? await Task.sleep(nanoseconds: UInt64(max(15, interval) * 1_000_000_000))
            }
        }
    }

    /// 深/淺色切換時選單列徽章需重烤(NSImage 顏色是預先算好的)。
    private func observeAppearanceChanges() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.appearanceTick += 1 }
        }
    }

    func refreshNow() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        let outcome = await coordinator.refresh()
        dashboard = outcome.dashboard
        activeMinutesToday = await coordinator.activeMinutesToday()

        handleTransitions(outcome.transitions)

        if settings.appMode == .full {
            let engine = feedingEngine
            engine.tick(activeMinutesToday: activeMinutesToday, tokensToday: dashboard.todayTotals.total)
            if dashboard.limitStates.contains(where: { $0.warning == .warning || $0.warning == .exhausted }) {
                engine.noteWarningSeen()
            }
            petState = engine.state
            treatsAvailable = engine.treatsAvailable(activeMinutesToday: activeMinutesToday)
            mood = MoodEngine.evaluate(dashboard: dashboard, pet: petState,
                                       warnThreshold: settings.core.warnThresholdPercent)
        }

        // 任何範圍(含 custom)都要跟著刷新,否則專案表會停留在舊資料。
        await reloadProjectPage()
    }

    func fullReindex() async {
        reindexing = true
        defer { reindexing = false }
        let outcome = await coordinator.refresh(fullReindex: true)
        dashboard = outcome.dashboard
        await reloadProjectPage()
    }

    private func handleTransitions(_ transitions: [LimitTransition]) {
        for transition in transitions {
            switch transition {
            case let .reset(providerId, window):
                if settings.appMode == .full {
                    feedingEngine.celebrate(until: Date().addingTimeInterval(120))
                    petState = feedingEngine.state
                }
                notify(title: "Quota reset 🎉", body: "\(providerName(providerId)) \(window) window has reset.")
            case let .crossedThreshold(providerId, window, percent, threshold):
                notify(title: "Usage warning",
                       body: "\(providerName(providerId)) \(window) window at \(Int(percent))% (threshold \(Int(threshold))%).")
            case let .exhausted(providerId, window):
                notify(title: "Quota exhausted",
                       body: "\(providerName(providerId)) \(window) window is fully used.")
            }
        }
    }

    private func notify(title: String, body: String) {
        guard settings.notificationsEnabled, !settings.quietMode else { return }
        // Snooze Alerts:期限內靜音通知;追蹤與 UI 照常更新
        if let until = settings.alertsSnoozedUntil, until > Date() { return }
        Notifier.post(title: title, body: body)
    }

    // MARK: - Snooze Alerts

    /// 目前有效的 snooze 期限(過期視同未 snooze)。
    var activeSnoozeUntil: Date? {
        guard let until = settings.alertsSnoozedUntil, until > Date() else { return nil }
        return until
    }

    func snoozeAlerts(for duration: TimeInterval) {
        updateSettings { $0.alertsSnoozedUntil = Date().addingTimeInterval(duration) }
    }

    func snoozeAlertsUntilTomorrow() {
        let cal = Calendar.current
        let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        updateSettings { $0.alertsSnoozedUntil = tomorrow }
    }

    func cancelSnooze() {
        updateSettings { $0.alertsSnoozedUntil = nil }
    }

    func providerName(_ id: String) -> String {
        dashboard.snapshots.first { $0.providerId == id }?.displayName ?? id
    }

    // MARK: - 設定

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        let oldMode = settings.appMode
        settingsStore.update(mutate)
        settings = settingsStore.settings
        // 串接成序列:第 N 次推送先 await 第 N-1 次,coordinator 收斂到最後寫入的值。
        let core = settings.core
        let previousPush = settingsPushTask
        settingsPushTask = Task { [weak self] in
            _ = await previousPush?.value
            await self?.coordinator.updateSettings(core)
        }
        if oldMode != settings.appMode {
            applyModeSideEffects()
        } else {
            petPanel?.apply(settings: settings)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        updateSettings { $0.launchAtLogin = on }
        LaunchAtLogin.setEnabled(on)
    }

    /// 模式切換的核心:monitor-only 完全銷毀寵物視窗與動畫(省 RAM),
    /// 而不是單純隱藏。
    private func applyModeSideEffects() {
        switch settings.appMode {
        case .full:
            _ = feedingEngine // 載回持久化的寵物狀態
            if petPanel == nil { petPanel = PetPanelController(model: self) }
            petPanel?.apply(settings: settings)
            if settings.petVisible { petPanel?.show() }
        case .monitorOnly:
            petPanel?.destroy()
            petPanel = nil
            feeding = nil // 釋放互動引擎;寵物狀態已持久化,切回 full 會載回
        }
    }

    func savePetPosition(_ origin: CGPoint) {
        settingsStore.update {
            $0.petPositionX = origin.x
            $0.petPositionY = origin.y
        }
        settings = settingsStore.settings
    }

    // MARK: - 餵食

    /// 餵食失敗的原因說明(寵物泡泡顯示;寵物隱藏時退回系統通知)。
    private(set) var feedNotice: (text: String, at: Date)?

    @discardableResult
    func feed(_ food: FoodItem) -> FeedingEngine.FeedResult {
        guard settings.appMode == .full else { return .notHungry }
        let engine = feedingEngine
        let result = engine.feed(food, activeMinutesToday: activeMinutesToday)
        petState = engine.state
        treatsAvailable = engine.treatsAvailable(activeMinutesToday: activeMinutesToday)
        switch result {
        case .ok:
            mood = MoodEngine.evaluate(dashboard: dashboard, pet: petState,
                                       warnThreshold: settings.core.warnThresholdPercent)
        case .notHungry:
            postFeedNotice("I'm full! (fullness \(Int(petState.hunger))%)")
        case .noTreats:
            postFeedNotice("no treats — earn 1 per 25 min of real work")
        case .kibbleLimitReached:
            postFeedNotice("kibble cap reached for today")
        }
        return result
    }

    private func postFeedNotice(_ text: String) {
        feedNotice = (text, Date())
        if !settings.petVisible {
            notify(title: "Feeding", body: text)
        }
    }

    // MARK: - Projects 頁範圍

    func currentRange(now: Date = Date()) -> DateInterval {
        let cal = Calendar.current
        switch rangePreset {
        case .today:
            return .today(now: now)
        case .yesterday:
            return .day(containing: cal.date(byAdding: .day, value: -1, to: now)!)
        case .last7Days:
            return DateInterval(start: cal.startOfDay(for: cal.date(byAdding: .day, value: -6, to: now)!), end: now)
        case .thisWeek:
            let start = cal.dateInterval(of: .weekOfYear, for: now)!.start
            return DateInterval(start: start, end: now)
        case .lastWeek:
            let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)!
            return DateInterval(start: cal.date(byAdding: .day, value: -7, to: thisWeek.start)!, end: thisWeek.start)
        case .allTime:
            // 涵蓋整個本機歷史(帳本有保留期上限,起點取足夠早即可)
            return DateInterval(start: Date(timeIntervalSince1970: 0), end: now)
        case .custom:
            let start = cal.startOfDay(for: customStart)
            let end = min(cal.startOfDay(for: customEnd).addingTimeInterval(86400), Date())
            return DateInterval(start: start, end: max(end, start.addingTimeInterval(60)))
        }
    }

    func reloadProjectPage() async {
        projectPage = await coordinator.projectPage(range: currentRange())
    }

    // MARK: - 匯出

    func exportReport(kind: ReportKind, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.title = "Export HTML Report"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let summary = settings.appMode == .full
            ? "\(settings.species.displayName) mood: \(mood.mood.rawValue) · level \(petState.level) · \(mood.summary)"
            : nil
        Task {
            do {
                try await coordinator.exportReport(kind: kind, to: url, petSummary: summary)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                notifyExportFailure(error)
            }
        }
    }

    private func notifyExportFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Export failed"
        alert.informativeText = String(describing: error)
        alert.runModal()
    }

    func exportToday() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        exportReport(kind: .today, suggestedName: "AIPetUsage-Report-\(df.string(from: Date())).html")
    }

    func exportCurrentRange() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let range = currentRange()
        let name = "AIPetUsage-Report-\(df.string(from: range.start))-to-\(df.string(from: range.end)).html"
        exportReport(kind: .range(range, title: "Usage Report — \(rangePreset.displayName)"), suggestedName: name)
    }

    // MARK: - 選單列

    /// 外觀(深/淺)切換計數:label 讀取它以觸發重烤。
    private(set) var appearanceTick = 0

    /// 選單列徽章(UIUX spec P0):物種 emoji 開頭、依顯示名稱字母序、
    /// 略過無資料 provider、identity dot 恆定、severity 只上在百分比。
    var menuBarBadges: [MenuBadge] {
        guard settings.menuBarDisplayMode != .petOnly else { return [] }
        let states = dashboard.limitStates.map { st in
            (id: st.providerId,
             displayName: dashboard.snapshots.first { $0.providerId == st.providerId }?.displayName,
             percent: st.fiveHour.usedPercent)
        }
        return MenuBadgeBuilder.badges(from: states,
                                       warn: settings.core.warnThresholdPercent,
                                       danger: settings.core.dangerThresholdPercent,
                                       onlyWarnings: settings.menuBarDisplayMode == .compact)
    }

    /// 選單列開頭標記:full 模式用所選物種,monitor-only 用 🐾。
    var menuBarPetEmoji: String {
        settings.appMode == .full ? settings.species.emoji : "🐾"
    }

    /// Full 模式且完全無資料時顯示「—」佔位;Compact/PetOnly 留空是語意本身。
    var menuBarShowsPlaceholder: Bool {
        settings.menuBarDisplayMode == .full && menuBarBadges.isEmpty
    }

    /// 輔助功能全句(spec §11):全名 + severity,不得只給短代號。
    var menuBarAccessibilityLabel: String {
        MenuBadgeBuilder.accessibilitySummary(
            petName: settings.appMode == .full ? settings.species.displayName : "AI Pet Usage",
            badges: menuBarBadges)
    }

    /// 純文字後備(NSImage 烤製失敗時);不再夾帶心情/警示 emoji(spec P0)。
    var menuBarTitle: String {
        let parts = menuBarBadges.map { "\($0.code)\($0.percent)%" }
        let usage = parts.isEmpty ? (menuBarShowsPlaceholder ? "—" : "") : parts.joined(separator: " ")
        return usage.isEmpty ? menuBarPetEmoji : "\(menuBarPetEmoji) \(usage)"
    }

    /// 依顯示名稱字母序的穩定排序(選單列、面板、儀表板一致;spec §5)。
    var orderedLimitStates: [ProviderLimitState] {
        dashboard.limitStates.sorted {
            ProviderBrands.brand(for: $0.providerId).displayName.lowercased() <
            ProviderBrands.brand(for: $1.providerId).displayName.lowercased()
        }
    }

    var orderedSnapshots: [UsageSnapshot] {
        dashboard.snapshots.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    /// 面板 header 的警示摘要(spec §8):取最嚴重的一條,一句話、不加 emoji。
    var alertSummary: (text: String, isDanger: Bool)? {
        var worst: (name: String, window: String, percent: Double, reset: Date?)?
        for st in orderedLimitStates {
            for (label, w) in [("5h", st.fiveHour), ("weekly", st.weekly)] {
                guard let p = w.usedPercent, p >= settings.core.warnThresholdPercent else { continue }
                if worst == nil || p > worst!.percent {
                    worst = (providerName(st.providerId), label, p, w.resetAt)
                }
            }
        }
        guard let w = worst else { return nil }
        let verb = w.percent >= 100 ? "exceeded" : "nearing"
        var text = "\(w.name) \(verb) \(w.window) limit"
        if let reset = w.reset { text += " · resets in \(countdown(to: reset))" }
        return (text, w.percent >= settings.core.dangerThresholdPercent)
    }

    // MARK: - 螢幕漫遊(pixel pet)

    /// -1 左行 / 0 靜止 / 1 右行;由 PetPanelController 的漫遊迴圈驅動,PetView 據此切換走路動畫與翻面。
    private(set) var wanderDirection: Int = 0

    func setWanderDirection(_ direction: Int) {
        if wanderDirection != direction { wanderDirection = direction }
    }
}
