import SwiftUI
import UsageCore
import PetCore

// MARK: - 共用格式化

func tk(_ n: Int) -> String { ReportGenerator.fmtTokens(n) }

/// 成本顯示規則(review #7):定價缺失時不得看起來像「花費 $0」。
/// **單一 sink 已移入 UsageCore.ReportGenerator.costDisplay**(§7;M2a 測試可斷言、GUI 與報告共用一份)。
/// 此處保留薄委派,GUI 呼叫點不變。
func costDisplay(_ c: CostResult) -> (value: String, caption: String?) { ReportGenerator.costDisplay(c) }

func costText(_ c: CostResult) -> String { costDisplay(c).value }

func countdown(to date: Date?, now: Date = Date()) -> String {
    // 邏輯移至 UsageCore.ResetLabel(可單元測試;menu 面板 compact reset 共用同一倒數)。
    ResetLabel.countdown(to: date, now: now)
}

func timeAgo(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "never" }
    let s = now.timeIntervalSince(date)
    if s < 60 { return "just now" }
    if s < 3600 { return "\(Int(s / 60))m ago" }
    if s < 86400 { return "\(Int(s / 3600))h ago" }
    return "\(Int(s / 86400))d ago"
}

// MARK: - 根視圖(工具列統一 Export,依分頁切換行為)

enum DashboardTab: Hashable {
    case today, limits, projects, trends
}

struct DashboardRoot: View {
    @Environment(AppModel.self) private var model
    @State private var tab: DashboardTab = .today

    var body: some View {
        TabView(selection: $tab) {
            TodayView().tabItem { Label("Today", systemImage: "sun.max") }.tag(DashboardTab.today)
            LimitsView().tabItem { Label("Limits", systemImage: "gauge.with.needle") }.tag(DashboardTab.limits)
            // isActive:Projects 是否為當前分頁。切離→硬關 hover;切回→重建 hover viewport + 重發列幾何
            // (owner spike-repair B:切 tab 回來 hover 不得依賴 range refresh 才復活)。`tab` 是本地 @State,
            // 於 body 讀取不違反 RAM-P0 的 Observation 隔離(只追蹤 $tab,不回讀 model 可觀測屬性)。
            ProjectsView(isActive: tab == .projects)
                .tabItem { Label("Projects", systemImage: "folder") }.tag(DashboardTab.projects)
            TrendsView().tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }.tag(DashboardTab.trends)
        }
        .frame(minWidth: 860, minHeight: 600)
        .onAppear { model.dashboardOpened() }
        .onDisappear { model.dashboardClosed() }
        .toolbar {
            // macOS 26 玻璃工具列會把同一 ToolbarItemGroup 的項目合進一顆共用膠囊:
            // 「Refreshed just now」溢出膠囊寬、刷新中 spinner 與分享鈕黏成一團、
            // 深色下膠囊幾乎不可見(2026-08-08 使用者回報)。改為:文字退出膠囊
            // (sharedBackgroundVisibility(.hidden)),兩鈕之間以固定 spacer 斷開
            // → 各自獨立氣泡。macOS <26 沿用原本的群組(無此問題)。
            // `#if compiler(>=6.2)`:`#available` 只是 runtime 分支,編譯期仍要 SDK 含
            // ToolbarSpacer / sharedBackgroundVisibility 符號 —— 舊工具鏈(CI macos-15
            // = Swift 6.1 / macOS 15 SDK)必須整段排除,否則 cannot find in scope
            // (CI 紅字 2026-08-09)。Xcode 26(Swift ≥6.2)起才編 26-only 分支。
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                ToolbarItem { refreshedLabel }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem { refreshButton }
                ToolbarSpacer(.fixed)
                ToolbarItem { exportButton }
            } else {
                legacyToolbarGroup
            }
            #else
            legacyToolbarGroup
            #endif
        }
    }

    /// macOS <26(或舊 SDK 編譯)的原始工具列群組。
    @ToolbarContentBuilder private var legacyToolbarGroup: some ToolbarContent {
        ToolbarItemGroup {
            refreshedLabel
            refreshButton
            exportButton
        }
    }

    // Observation 隔離(RAM P0 2026-09-02):工具列兩個每-tick 變動的讀取
    // (dashboard.lastRefreshAt、refreshing)必須住在自己的子 view,讓
    // DashboardRoot.body 只追蹤 $tab。容器 body 每次重評都重建 TabView 的
    // view-list,而 macOS 26 SwiftUI 把每組 tabItem(4 個 Label + TagIndexProjection)
    // 記進 selection StoredLocation 的內部字典且永不回收 —— 視窗開著時每 tick
    // 洩約 4 組、重度使用數日累積數百 MB(retain-path 證據:兩個相距 14k 的
    // 物件皆收斂到同一 StoredLocation<DashboardTab>;reviews/ram-p0-2026-09-02/)。
    // 勿把 model 的可觀測屬性讀回 DashboardRoot.body。
    private var refreshedLabel: some View { RefreshedToolbarLabel() }

    private var refreshButton: some View { RefreshToolbarButton() }

    private var exportButton: some View {
        Button {
            switch tab {
            case .today, .limits: model.exportToday()
            case .projects: model.exportCurrentRange()
            case .trends: model.exportTrends()
            }
        } label: {
            Label(exportLabel, systemImage: "square.and.arrow.up")
        }
        .help("Export a self-contained local HTML report")
    }

    private var exportLabel: String {
        switch tab {
        case .today: return "Export Today"
        case .limits: return "Export Snapshot"
        case .projects: return "Export Range"
        case .trends: return "Export Trends"
        }
    }
}

/// DashboardRoot 工具列的「Refreshed …」標籤;獨立 view = Observation 追蹤邊界
/// (見 DashboardRoot 內註解;此處變動只重評本 view,不重建 TabView view-list)。
private struct RefreshedToolbarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // L1(xcheck r1 luna):補讀 refreshing —— 恢復修前「refresh 開始/結束都順帶重算
        // 相對時間」的節奏;依賴留在本 child,DashboardRoot/TabView 的隔離不回退。
        let _ = model.refreshing
        if let last = model.dashboard.lastRefreshAt {
            Text("Refreshed \(timeAgo(last))")
                .font(Theme.FontScale.secondaryInfo)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()   // 完整呈現,不被工具列裁切
        }
    }
}

/// DashboardRoot 工具列的刷新鈕;獨立 view 隔離 refreshing 的每-tick 翻轉。
private struct RefreshToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            Task { await model.userRefresh() }
        } label: {
            if model.refreshing { ProgressView().controlSize(.small) }
            else { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .keyboardShortcut("r")
    }
}

// MARK: - 元件

struct StatTile<Extra: View>: View {
    let title: String
    let value: String
    var caption: String? = nil
    @ViewBuilder var extra: Extra

    init(title: String, value: String, caption: String? = nil,
         @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.title = title
        self.value = value
        self.caption = caption
        self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.FontScale.secondaryInfo).foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(value.count > 14 ? .headline : Theme.FontScale.metric)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            extra
            if let caption {
                Text(caption).font(Theme.FontScale.secondaryInfo).foregroundStyle(Theme.textMuted)
                    .lineLimit(2).truncationMode(.tail)
            }
        }
        // A3:在等高列(HStack + fixedSize)中填滿列高 → 同列卡片一致;
        // 不拉伸的容器(LazyVGrid)行為不變(自然高度)。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 等高統計列(A3/D8):列高 = 最高卡;搭配 StatTile 的 maxHeight 填滿。
struct EqualHeightTileRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 10) { content }
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 訂閱方案 chip(A7 UI 呈現):全小寫單字(codex 的 "plus")首字大寫;其餘原樣。
struct PlanChip: View {
    let plan: String

    private var pretty: String {
        let isSingleLowercaseWord = !plan.isEmpty && plan == plan.lowercased()
            && !plan.contains(where: { $0 == " " || $0 == "_" })
        return isSingleLowercaseWord ? plan.prefix(1).uppercased() + plan.dropFirst() : plan
    }

    var body: some View {
        Text(pretty).font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(Theme.textSecondary)
    }
}

/// Total tokens 卡片內的 in/out/cache 迷你堆疊條(review #9)。
struct TokenMixBar: View {
    let breakdown: TokenBreakdown

    var body: some View {
        let totalTokens = breakdown.total
        let total = max(1, totalTokens)
        let input = Double(breakdown.input) / Double(total)
        let output = Double(breakdown.output) / Double(total)
        let cache = Double(breakdown.cacheRead + breakdown.cacheWrite) / Double(total)
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geo in
                if totalTokens == 0 {
                    Capsule()
                        .fill(Theme.textDisabled.opacity(0.15))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    HStack(spacing: 1) {
                        if breakdown.input > 0 {
                            Rectangle().fill(Color.accentColor).frame(width: max(1, geo.size.width * input))
                        }
                        if breakdown.output > 0 {
                            Rectangle().fill(Color.teal).frame(width: max(1, geo.size.width * output))
                        }
                        if breakdown.cacheRead + breakdown.cacheWrite > 0 {
                            Rectangle().fill(Theme.textDisabled).frame(width: max(1, geo.size.width * cache))
                        }
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: 5)
            Text(mixLabel)
                .font(Theme.FontScale.secondaryInfo)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// 三段合計恆 ≤100(largest-remainder)。"<1%" 判準用**實際占比 < 0.5%**,不是
    /// 「配不到 1」:[1, 1, 199] 配額為 [1, 0, 99],兩個同值段若一個顯 1%、一個顯 <1%
    /// 會自相矛盾(xcheck r1)—— 實際占比判準下兩者一致顯示 "<1%"。
    private var mixLabel: String {
        let cacheTokens = breakdown.cacheRead + breakdown.cacheWrite
        let totalD = Double(max(1, breakdown.total))
        let parts = [breakdown.input, breakdown.output, cacheTokens]
        // 平手一致化:同值段不得一個 "1%" 一個 "<1%"(xcheck r2)。
        let shares = ReportGenerator.tieNormalizedShares(
            parts: parts, shares: ReportGenerator.integerPercentShares(parts))
        func label(_ part: Int, _ share: Int) -> String {
            guard part > 0 else { return "0%" }
            if share == 0 || Double(part) / totalD < 0.005 { return "<1%" }
            return "\(share)%"
        }
        return "in \(label(breakdown.input, shares[0])) · out \(label(breakdown.output, shares[1])) · cache \(label(cacheTokens, shares[2]))"
    }
}

struct StatusBadge: View {
    let status: ProviderStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .unavailable: return "not installed"
        case .noData: return "no data"
        case .stale: return "stale"
        case .healthy: return "healthy"
        case .warning: return "warning"
        case .exhausted: return "exhausted"
        case .error: return "error"
        }
    }

    private var color: Color {
        switch status {
        case .healthy: return .green
        case .warning, .stale: return .orange
        case .exhausted, .error: return .red
        case .noData, .unavailable: return .gray
        }
    }
}

/// Limits 頁 Claude 本機估算 bar(v0.8 A2b)。**顯示的 main / secondary 文字全部**來自
/// `EstimateBarText.render`(→ `EstimateRowText`);本 view 不自呼 `ResetLabel.countdown`、
/// 不讀 `Date()`、不自行格式化 tokens / % / `no budget set` / `rolling 7-day` —— 所有相對 reset
/// 文字由呼叫端注入的 `now` 控制,與 Today 卡 / CLI 同一張 estimate vocabulary。gauge 由 estimate-domain
/// `usedPercent` 餵、affordance 用抽出的共用 predicate(規則不改);`.help` 是固定句 chrome(非 vocabulary)。
struct EstimateBar: View {
    @Environment(\.openSettings) private var openSettings
    let title: String
    let window: LimitWindowState
    let kind: LimitWindowKind
    let now: Date
    let warn: Double
    var danger: Double = 99.5
    var showBudgetAffordance = false

    var body: some View {
        let m = EstimateBarText.render(window: window, kind: kind, now: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(m.main).font(.caption).monospacedDigit().foregroundStyle(Theme.textPrimary)
            }
            GaugeBar(percent: m.gaugePercent ?? 0, warn: warn, danger: danger)
                .frame(height: 6)
                .opacity(m.gaugePercent == nil ? 0.25 : 1)
            HStack {
                Text(m.secondary).font(Theme.FontScale.secondaryInfo).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            // affordance predicate byte-semantic unchanged(抽成共用 helper);chrome 保留。
            if BudgetAffordance.limitsEstimateBarShowsBudgetButton(window: window, showBudgetAffordance: showBudgetAffordance) {
                HStack(spacing: 6) {
                    Text("Percent unavailable").font(.caption2).foregroundStyle(Theme.textMuted)
                    Button("Set estimated budget…") {
                        NSApp.activate(ignoringOtherApps: true)
                        openSettings()
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                }
            }
        }
        .help(helpText)
    }

    /// idle / no-data 的固定說明句 tooltip(chrome;非 vocabulary —— 不格式化任何數值,只依 window 布林選一句)。
    private var helpText: String {
        if window.idle { return "No active 5h window found in local Claude logs." }
        if window.usedPercent == nil, window.usedTokens == nil, showBudgetAffordance {
            return "No local Claude usage found."
        }
        return ""
    }
}

/// 純 SwiftUI 長條時間軸:單一 plot-area hover,tooltip 跟隨游標(A4)。
struct HourlyChart: View {
    let buckets: [HourBucket]
    @State private var hoveredHour: Int?
    @State private var cursor: CGPoint = .zero

    private var slots: [Int] { Array(0...Calendar.current.component(.hour, from: Date())) }
    private var maxTokens: Int { max(1, buckets.map(\.tokens).max() ?? 1) }
    private var niceMax: Int { Int(niceCeiling(Double(maxTokens))) }

    /// 依面板寬度選出要標 X 軸的小時索引:slot 寬決定 clock-friendly 步距(1/2/3/4/6/12/24);
    /// 首格與當前(末)小時必標;移除與末格過近的倒數第二標(當前小時優先)。bar 少時 slotW
    /// 大 → step=1 → 每格皆標(早晨僅數根長條時的訴求)。跨模型合議(grok-4.5 max +
    /// gpt-5.6-sol max,2026-07-13)的寬度感知 nice-step 方案,取代原寫死的 `hour % 6`。
    static func axisLabelIndices(count n: Int, width: CGFloat) -> Set<Int> {
        guard n > 1 else { return [0] }
        let last = n - 1
        guard width > 0 else { return [0, last] }   // 退化版面(width 0):首末都保留
        let slotW = width / CGFloat(n)
        let minSpacing: CGFloat = 34   // 2 位數 micro 標籤 + 間距下限
        let rawStep = max(1, Int((minSpacing / slotW).rounded(.up)))
        let step = [1, 2, 3, 4, 6, 12, 24].first { $0 >= rawStep } ?? 24
        var ticks = Array(Swift.stride(from: 0, through: last, by: step))
        if ticks.last != last { ticks.append(last) }
        // 僅丟「內部」標(count≥3),永不丟首格 —— cross-model round-2(gpt-5.6-sol max)
        // 指出 count≥2 時倒數第二標可能就是 index 0,窄版面會破壞「首格必標」不變量。
        if ticks.count >= 3,
           CGFloat(last - ticks[ticks.count - 2]) * slotW < minSpacing {
            ticks.remove(at: ticks.count - 2)   // 當前小時優先
        }
        return Set(ticks)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Y 軸刻度(R4:動態寬,與 Trends 日圖一致)
            VStack(alignment: .trailing) {
                Text(tk(niceMax)).fixedSize()
                Spacer()
                Text(tk(niceMax / 2)).fixedSize()
                Spacer()
                Text("0")
            }
            .font(Theme.FontScale.micro)
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.bottom, 12)

            GeometryReader { geo in
                let barArea = geo.size.height - 12
                let n = max(1, slots.count)
                let slotW = geo.size.width / CGFloat(n)
                let labeled = Self.axisLabelIndices(count: n, width: geo.size.width)
                ZStack(alignment: .bottom) {
                    // 網格線
                    VStack {
                        Divider()
                        Spacer()
                        Divider()
                        Spacer()
                        Divider().opacity(0)
                    }
                    .padding(.bottom, 12)

                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(Array(slots.enumerated()), id: \.element) { i, hour in
                            let tokens = bucket(hour)?.tokens ?? 0
                            VStack(spacing: 2) {
                                // 零用量 → 1pt 淡基線,不得看起來有量(review 低項)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(hoveredHour == hour ? Color.accentColor
                                          : tokens > 0 ? Color.accentColor.opacity(0.75)
                                          : Theme.textDisabled.opacity(0.15))
                                    .frame(height: tokens > 0
                                           ? max(2, barArea * CGFloat(tokens) / CGFloat(niceMax))
                                           : 1)
                                // X 軸標籤:自適應步距(見 axisLabelIndices);%02d 對齊 tooltip 的 %02d:00。
                                Text(labeled.contains(i) ? String(format: "%02d", hour) : " ")
                                    .font(Theme.FontScale.micro)
                                    .foregroundStyle(Theme.textMuted)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .frame(height: 10)
                            }
                            // minWidth:0 + maxWidth:∞ 才會採用「提議寬度」等分;僅 maxWidth 時
                            // fixedSize 標籤的理想寬會變成 slot 最小寬,使有標格比空白格寬(cross-model
                            // round-2:gpt-5.6-sol max,Apple frame 文件)。label 溢出到空白鄰格不影響幾何。
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .bottom)
                            // VoiceOver:自訂 tooltip 不可達,逐 bar 保留朗讀標籤。
                            .accessibilityLabel("\(hour):00, \(tk(tokens)) tokens")
                        }
                    }
                    // 單一 plot hover:x → 小時(1px gap 不再斷線);tooltip 錨在游標。
                    // 槽距含 HStack spacing(grok P3-2):step = 寬/欄數即含均攤 gap,
                    // 用 floor 後 clamp(spacing 2 均攤進 maxWidth 槽,step ≈ slotW)。
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p):
                                cursor = p
                                let idx = min(max(0, Int((p.x / max(slotW, 1)).rounded(.down))), n - 1)
                                hoveredHour = slots[idx]
                            case .ended:
                                hoveredHour = nil
                            }
                        }
                    if let hour = hoveredHour {
                        CursorTooltip(cursor: cursor, container: geo.size) {
                            tooltipContent(for: hour)
                        }
                    }
                }
            }
        }
    }

    private func bucket(_ hour: Int) -> HourBucket? {
        let cal = Calendar.current
        return buckets.first { cal.component(.hour, from: $0.start) == hour }
    }

    @ViewBuilder
    private func tooltipContent(for hour: Int) -> some View {
        let b = bucket(hour)
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%02d:00", hour)).font(.caption.weight(.semibold))
            Text("Tokens: \(tk(b?.tokens ?? 0))").font(.caption)
            if let b {
                Text("in \(tk(b.breakdown.input)) · out \(tk(b.breakdown.output)) · cache \(tk(b.breakdown.cacheRead + b.breakdown.cacheWrite))")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
                if !b.byProvider.isEmpty {
                    Text("Agents: \(b.byProvider.keys.sorted().joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                if let project = b.topProject {
                    Text("Top project: \(project)").font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

// MARK: - Page 1: Today

struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let dash = model.dashboard
        let cost = costDisplay(dash.todayCost)
        // D46/D51:相對時間片段(`resets in …`)由投影顯式接收 `now`,整個 render cycle 共用一個時刻。
        let now = Date()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 首次使用/缺資料時的主動引導(不只被動空狀態)
                if dash.snapshots.contains(where: { $0.status == .noData || $0.status == .unavailable }) {
                    OnboardingCard(snapshots: dash.snapshots)
                }

                // A3:等高統計列(視窗 minWidth 860 保證單列容納;等高 = 最高卡)。
                EqualHeightTileRow {
                    StatTile(title: "Total tokens today", value: tk(dash.todayTotals.total)) {
                        TokenMixBar(breakdown: dash.todayTotals)
                    }
                    StatTile(title: "Estimated cost", value: cost.value, caption: cost.caption)
                    StatTile(title: "Burn rate", value: "\(tk(Int(dash.burnRateTokensPerHour)))/h",
                             caption: burnCaption(dash))
                    if model.settings.appMode == .full {
                        StatTile(title: "Pet",
                                 value: "\(model.speciesDisplayName) · \(model.mood.mood.rawValue)",
                                 caption: model.mood.reason)
                            .help("\(PetInfo.tooltip)\n\nLv.\(model.petState.level) · fullness \(Int(model.petState.hunger))%")
                    }
                }

                Text("Coding agents").font(Theme.FontScale.cardTitle)
                // owner spike-repair Phase 2:domain 說明從每張卡移到這條共用 caption(卡片因而 compact),
                // 但保留 Usage ≠ Limits 語意(本機用量 vs provider-reported 限額)。
                Text("Local usage on this Mac · provider-reported limits where available")
                    .font(.caption2).foregroundStyle(Theme.textMuted)
                // adaptive minimum 260→320:視窗較寬時偏好 ~3 張可讀卡,而非擠四張密卡(minWidth 860 → 2 欄)。
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 10)], spacing: 10) {
                    ForEach(model.orderedSnapshots) { snap in
                        AgentCard(snapshot: snap,
                                  limit: dash.limitStates.first { $0.providerId == snap.providerId },
                                  reported: dash.reportedLimits.first { $0.providerId == snap.providerId },
                                  now: now)
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Timeline (today, by hour)").font(Theme.FontScale.cardTitle)
                        HourlyChart(buckets: dash.hourly)
                            .frame(height: 130)
                            .padding(10)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top projects today").font(Theme.FontScale.cardTitle)
                        if dash.topProjects.isEmpty {
                            Text("No usage today yet.")
                                .font(Theme.FontScale.secondaryInfo)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        VStack(spacing: 3) {
                            // Share 欄整組配額(和恆 ≤100;top-N 是截斷子集,rowShares 把
                            // 「其餘」納入分母,xcheck r1 twin)。
                            let shownTop = Array(dash.topProjects.prefix(6))
                            let topShares = ReportGenerator.rowShares(
                                rows: shownTop.map { $0.tokens.total },
                                periodTotal: dash.todayTotals.total, scale: 100)
                            ForEach(Array(shownTop.enumerated()), id: \.element.id) { i, p in
                                ProjectShareRow(project: p, sharePercent: topShares[i])
                            }
                        }
                    }
                    .frame(width: 320)
                }

                if !dash.shareSafeDataQuality.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Data quality").font(Theme.FontScale.cardTitle)
                        // 分享安全:只渲染去識別後的投影(原文僅 CLI `aipet status --full`)。
                        // 以列舉索引為身分:去識別後多筆可能塌成同字串,`id: \.self` 會產生重複身分。
                        ForEach(Array(dash.shareSafeDataQuality.enumerated()), id: \.offset) { _, note in
                            Label(note, systemImage: "exclamationmark.triangle")
                                .font(Theme.FontScale.note)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func burnCaption(_ dash: DashboardState) -> String {
        if dash.burnCostPerHour >= 0.005 {
            return "≈ \(ReportGenerator.fmtUSD(dash.burnCostPerHour))/h"
        }
        return dash.todayCost.unknownModelTokens > 0 ? "cost rate unavailable" : "≈ $0.00/h"
    }
}

/// 首次使用引導卡:逐 provider 說明現況與下一步(規格要求的 no-data guidance)。
struct OnboardingCard: View {
    @Environment(\.openSettings) private var openSettings
    let snapshots: [UsageSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Getting started", systemImage: "sparkles")
                .font(Theme.FontScale.cardTitle)
            ForEach(snapshots.filter { $0.status == .noData || $0.status == .unavailable }) { snap in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(Theme.textMuted)
                    Text(guidance(for: snap))
                        .font(Theme.FontScale.secondaryInfo)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Open Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .controlSize(.small)
                Text("Everything is read locally — your usage data is never uploaded.")
                    .font(.caption2).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSubtle, in: RoundedRectangle(cornerRadius: 10))
    }

    private func guidance(for snap: UsageSnapshot) -> String {
        switch snap.status {
        case .unavailable:
            return "\(snap.displayName) is not detected on this Mac. Install its CLI and run one session — the app only reads its local log files (\(snap.sourceDescription))."
        case .noData:
            return "\(snap.displayName) is installed but has no usage events yet. Run one session, then press Refresh (⌘R). Data appears from local logs within seconds."
        default:
            return snap.displayName
        }
    }
}

/// Top projects 列:佔比以低對比背景條呈現(review #2),數字仍是主體。
/// `sharePercent` 由父層對整組列一次配額(largest-remainder)—— 逐列獨立捨入
/// 的和會超過 100%(xcheck r1 twin);背景條仍用連續的 raw 佔比。
struct ProjectShareRow: View {
    let project: ProjectSummary
    let sharePercent: Int

    var body: some View {
        HStack {
            Text(project.projectName).lineLimit(1).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(tk(project.tokens.total)).monospacedDigit().foregroundStyle(Theme.textSecondary)
            Text(project.tokens.total > 0 && sharePercent == 0 ? "<1%" : "\(sharePercent)%")
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(Theme.textMuted)
        }
        .font(.callout)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(alignment: .leading) {
            GeometryReader { geo in
                if project.shareOfPeriod > 0 {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Theme.accentSubtle)
                        .frame(width: max(3, geo.size.width * project.shareOfPeriod))
                }
            }
        }
    }
}

struct AgentCard: View {
    @Environment(\.openSettings) private var openSettings
    let snapshot: UsageSnapshot
    let limit: ProviderLimitState?
    /// provider-reported 四態投影(usage ≠ limits split,M1);與本機用量是兩個資料域。
    let reported: ProviderReportedLimits?
    /// 相對時間片段的單一時刻(D46/D51:投影不自讀 `Date()`)。
    let now: Date

    var body: some View {
        let brand = ProviderBrands.brand(for: snapshot.providerId, displayName: snapshot.displayName)
        // owner spike-repair Phase 2(compact 卡):domain 說明移到「Coding agents」下的共用 caption;每卡不再重複
        // 「Local observed usage…」與 per-provider 的 provider-reported 標題。行數不再強制恆等(A3 的恆-7-行由 owner
        // 明示放棄:不留恆置 `—` 佔位)。底層 UsageSnapshot / limits 語意完全不變 —— 純呈現。
        VStack(alignment: .leading, spacing: 6) {
            // 1. header(dot + 名稱 + 方案 chip + 狀態)
            HStack(spacing: 6) {
                ProviderDot(brand: brand)
                Text(snapshot.displayName).font(Theme.FontScale.cardTitle)
                if let plan = limit?.planType {
                    PlanChip(plan: plan)   // A7:訂閱方案 chip(Max 20x / Plus / SuperGrok)
                }
                Spacer()
                StatusBadge(status: snapshot.status)
            }
            .help("\(brand.displayName) — shown as \(brand.code) in the menu bar and pet gauges")

            // 2. 本機用量:today 大數字 + in/out/cache(domain 由共用 caption 標示)
            metric("today", tk((snapshot.tokenInput ?? 0) + (snapshot.tokenOutput ?? 0) + (snapshot.tokenCache ?? 0)))
            Text("in \(tk(snapshot.tokenInput ?? 0)) · out \(tk(snapshot.tokenOutput ?? 0)) · cache \(tk(snapshot.tokenCache ?? 0))")
                .font(Theme.FontScale.secondaryInfo)
                .foregroundStyle(Theme.textSecondary)

            // 3. provider-reported 限額:5h/weekly 併一行;整組不提供 → 單行(不重複兩次 Not provided)。四態投影不變。
            limitsLine

            // 4. estimate:僅在有 active estimate 窗時 render(非 claude / 缺載體 / official 治理中 → 不渲染,
            // 不留恆置 `—`)。行只在 claude 有內容時出現,故不再需要舊那條「available for Claude Code only」help。
            if let est = meaningfulEstimateLine {
                Text(est)
                    .font(Theme.FontScale.secondaryInfo).foregroundStyle(Theme.textMuted)
            }

            // 5. Set estimated budget 按鈕(predicate 與今日 byte-identical;estimate 域控制,D13)
            if BudgetAffordance.todayButtonVisible(snapshot: snapshot, limit: limit) {
                Button("Set estimated budget…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
            // 6. 既有 shareSafeError 行(條件行,不改;error 保持可見)
            if let err = snapshot.shareSafeError {
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(12)
        // owner spike#3 §3:卡片填滿 LazyVGrid 列高 → 同一列的 Claude/Codex/Grok 灰卡等高(不靠假 `—` 佔位)。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    /// provider-reported 限額(compact):兩窗皆 `.notProvidedBySource`(adapter capability 明示不提供)→ 單行;
    /// 否則 5h / weekly 各自**一列**(owner spike #2 refinement:不再併一行——併一行太密、會換行;改固定寬度標籤欄
    /// 讓兩列數值對齊)。provided / temporarilyUnavailable / 混合皆帶真實資訊。缺載體 → 單行中性佔位。
    @ViewBuilder
    private var limitsLine: some View {
        if let reported {
            if isNotProvided(reported.fiveHour) && isNotProvided(reported.weekly) {
                // owner spike#3 §3:整組不提供 → 兩列(語意同「單行 Not provided」,純呈現)。
                VStack(alignment: .leading, spacing: 2) {
                    Text("Limits")
                    Text("Not provided by this source")
                }
                .font(Theme.FontScale.secondaryInfo).foregroundStyle(Theme.textMuted)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    limitRow("5h", reportedInline(\.fiveHour))
                    limitRow("weekly", reportedInline(\.weekly))
                }
                .font(Theme.FontScale.secondaryInfo).foregroundStyle(Theme.textSecondary)
            }
        } else {
            Text("Limits · —")
                .font(Theme.FontScale.secondaryInfo).foregroundStyle(Theme.textMuted)
        }
    }

    /// 一列限額:固定寬度標籤欄(5h / weekly 對齊)+ 值。
    private func limitRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 46, alignment: .leading).foregroundStyle(Theme.textMuted)
            Text(value)
        }
    }

    private func isNotProvided(_ field: ReportedLimitField) -> Bool {
        if case .notProvidedBySource = field { return true }
        return false
    }

    /// 四態單行文字(主文,次行非空時接 ` · 次行`);載體缺席時 `—`(A3 佔位,不縮行)。
    private func reportedInline(_ kp: KeyPath<ProviderReportedLimits, ReportedLimitField>) -> String {
        guard let reported else { return "—" }
        return ReportedLimitText.inline(field: reported[keyPath: kp], cue: reported.cue, now: now)
    }

    /// Today 卡第 7 行:claude 至少一窗 active → estimate 文字;非 claude / 載體缺席 → `—`。
    private var estimateLine: String {
        guard let reported, let limit else { return "—" }
        return EstimateRowText.todayLine(reported: reported, limit: limit, now: now)
    }

    /// estimate 列文字,僅在有 active estimate 窗時回傳(claude-code ∧ official ∈ {expiredUnusable, absent},
    /// 即 `EstimateRowText.todayLine` :248 產生實質內容的同一訊號);否則 nil → compact 卡不渲染該行
    ///(隱藏非 claude 的 `—`,也隱藏「official 窗治理中」的 `… · —` 尾巴,對齊 owner mockup)。
    private var meaningfulEstimateLine: String? {
        guard let reported, reported.fiveHourEstimateActive || reported.weeklyEstimateActive else { return nil }
        let line = estimateLine
        return (line == "—" || line.isEmpty) ? nil : line
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(Theme.textMuted)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }
}

// MARK: - Page 2: Limits

struct LimitsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let dash = model.dashboard
        // D46/D51:相對時間片段共用單一 `now`。
        let now = Date()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.orderedLimitStates) { limit in
                    LimitRow(limit: limit,
                             snapshot: dash.snapshots.first { $0.providerId == limit.providerId },
                             reported: dash.reportedLimits.first { $0.providerId == limit.providerId },
                             now: now,
                             warn: model.settings.core.warnThresholdPercent,
                             danger: model.settings.core.dangerThresholdPercent)
                }

                // D7:提示改由 presence 驅動 —— 任一 hook 落地檔皆不存在(`.hookNotInstalled` 的超集,
                // 殘留 provided 期間也顯);不再用 `usedPercent == nil` 猜。提示句不改字。
                if dash.reportedLimits.first(where: { $0.providerId == "claude-code" })?.statuslinePresent == false {
                    Label("Claude Code official limits appear automatically when a statusline hook saves Claude Code's payload locally — run `aipet install-hook` once to set it up (if your statusLine already points at a script, it wraps that script untouched). Without it, set an estimated token budget in Settings → Limits.",
                          systemImage: "info.circle")
                        .font(Theme.FontScale.note)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(16)
        }
    }
}

struct LimitRow: View {
    let limit: ProviderLimitState
    let snapshot: UsageSnapshot?
    /// provider-reported 四態投影;與本機估算是兩個資料域。
    let reported: ProviderReportedLimits?
    /// 相對時間片段的單一時刻(D46/D51)。
    let now: Date
    let warn: Double
    var danger: Double = 99.5

    var body: some View {
        let brand = ProviderBrands.brand(for: limit.providerId, displayName: snapshot?.displayName)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ProviderDot(brand: brand)
                Text(snapshot?.displayName ?? limit.providerId).font(Theme.FontScale.cardTitle)
                if let plan = limit.planType {
                    PlanChip(plan: plan)   // A7:與 Today 卡同一呈現("plus" → "Plus")
                }
                Spacer()
                if let snapshot { StatusBadge(status: snapshot.status) }
            }
            .help("\(brand.displayName) — shown as \(brand.code) in the menu bar and pet gauges")
            // provider-reported 標題(封閉字串;與 Today 卡同一張表)
            Text(ReportedLimitText.header(providerId: limit.providerId))
                .font(.caption2).foregroundStyle(Theme.textMuted)
            // provider-reported 兩條 bar:只吃投影輸出 + corrected chrome(D27:型別上進不了 affordance)
            HStack(alignment: .top, spacing: 24) {
                reportedBar("5-hour window", reported?.fiveHour ?? .unknownCapability)
                reportedBar("Weekly window", reported?.weekly ?? .unknownCapability)
            }
            // 本機估算 bar(v0.8 A2b:新 EstimateBar,文字全來自 EstimateRowText、reset 由注入 now 控制):
            // 只 claude、只該窗 estimate active 時渲染(D16/D30)
            if let reported, reported.providerId == "claude-code",
               reported.fiveHourEstimateActive || reported.weeklyEstimateActive {
                HStack(alignment: .top, spacing: 24) {
                    if reported.fiveHourEstimateActive {
                        EstimateBar(title: "Estimated from local logs (your budget) · 5-hour",
                                    window: limit.fiveHour, kind: .fiveHour, now: now,
                                    warn: warn, danger: danger, showBudgetAffordance: true)
                    }
                    if reported.weeklyEstimateActive {
                        EstimateBar(title: "Estimated from local logs (your budget) · Weekly",
                                    window: limit.weekly, kind: .weekly, now: now,
                                    warn: warn, danger: danger, showBudgetAffordance: true)
                    }
                }
            }
            HStack(spacing: 16) {
                Label("\(tk(Int(limit.burnRateTokensPerHour)))/h burn", systemImage: "flame")
                if let projected = limit.projectedExhaustionAt {
                    Label("limit in ~\(countdown(to: projected))", systemImage: "hourglass")
                        .foregroundStyle(projected.timeIntervalSinceNow < 5400 ? .orange : Theme.textSecondary)
                }
                if let lastEvent = limit.lastEventAt {
                    Label("last event \(timeAgo(lastEvent))", systemImage: "clock")
                }
                Spacer()
            }
            .font(Theme.FontScale.secondaryInfo)
            .foregroundStyle(Theme.textSecondary)
            if let source = limit.lastSourceDescription {
                Text(source).font(.caption2).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    /// provider-reported bar:由投影輸出(main / secondary / gaugePercent)+ corrected chrome 建構。
    /// 這裡是唯一呼叫 `ReportedLimitText.render` 的地方;`ReportedLimitBar` 本身收不到 `LimitWindowState`。
    private func reportedBar(_ title: String, _ field: ReportedLimitField) -> ReportedLimitBar {
        let r = ReportedLimitText.render(field: field, cue: reported?.cue ?? .none, now: now)
        var corrected = false
        if case .provided(_, _, _, let c) = field { corrected = c }
        return ReportedLimitBar(title: title, main: r.main, secondary: r.secondary,
                                gaugePercent: r.gaugePercent, corrected: corrected, warn: warn, danger: danger)
    }
}

/// provider-reported 限額的 bar(D27):輸入**只有** `ReportedLimitText` 投影輸出 + `corrected` chrome 旗標。
/// 刻意**沒有** `LimitWindowState` / `showBudgetAffordance` 參數 —— 型別層保證 `Percent unavailable` /
/// `Set estimated budget…` 這類 estimate 域 affordance 絕不會出現在 provider-reported 區塊。
struct ReportedLimitBar: View {
    let title: String
    let main: String
    let secondary: String
    /// nil = 非 provided → 空軌、無 % 文字(不再 `usedPercent ?? 0`)。
    let gaugePercent: Double?
    let corrected: Bool
    let warn: Double
    var danger: Double = 99.5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(main).font(.caption).monospacedDigit().foregroundStyle(Theme.textPrimary)
            }
            GaugeBar(percent: gaugePercent ?? 0, warn: warn, danger: danger)
                .frame(height: 6)
                .opacity(gaugePercent == nil ? 0.25 : 1)
            HStack {
                Text(secondary).font(Theme.FontScale.secondaryInfo).foregroundStyle(Theme.textSecondary)
                Spacer()
                if corrected {
                    Text("corrected").font(.caption2).foregroundStyle(.orange)   // chrome(不進次行片段)
                }
            }
        }
    }
}

// MARK: - Page 3: Projects(自繪表格:載入後不出現空白填充列,review #6)

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    let isActive: Bool   // 由 DashboardRoot 傳入:Projects 是否為當前分頁(驅動 ProjectTable 的 hover re-arm)

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Range", selection: $model.rangePreset) {
                    ForEach(RangePreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: model.rangePreset) {
                    Task { await model.reloadProjectPage() }
                }
                Spacer()
            }

            if model.rangePreset == .custom {
                HStack {
                    // R3(三方裁定 A):en_CA locale → yyyy-MM-dd 零補位,消除系統
                    // locale 的「 6/ 7/2026」空白補位與 D/M 歧義,並與 app 全域日期
                    // 格式一致。只套在這兩個 picker,不外擴(codex 條件)。
                    DatePicker("From", selection: $model.customStart, displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "en_CA"))
                    DatePicker("To", selection: $model.customEnd, displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "en_CA"))
                    Button("Apply") { Task { await model.reloadProjectPage() } }
                }
                .font(.caption)
            }

            if let page = model.projectPage {
                let cost = costDisplay(page.cost)
                // A3:與 Today/Trends 同一等高模式(移除硬編 height 80)。
                EqualHeightTileRow {
                    StatTile(title: "Period tokens", value: tk(page.totals.total))
                    StatTile(title: "Period cost", value: cost.value, caption: cost.caption)
                    StatTile(title: "Projects", value: "\(page.projects.count)")
                    StatTile(title: "Models", value: "\(page.models.count)")
                }

                ProjectTable(projects: page.projects, projectModels: page.projectModels, isActive: isActive,
                             pageStamp: ProjectPageStamp(revision: page.revision, pricingStamp: page.pricingStamp,
                                                         range: page.range))

                // Usage-M2a — global provider-scoped "By model" breakdown(消費既有 page.models,
                // 身分已硬化;純顯示、零重掃、無 provider-limit %、無 sessions)。
                Text("By model")
                    .font(Theme.FontScale.cardTitle)
                    .padding(.top, 4)
                ByModelTable(models: page.models)
            } else {
                Spacer()
                ProgressView("Loading…").frame(maxWidth: .infinity)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .task { await model.reloadProjectPage() }
    }
}

/// Usage-M3 A1(ROW-ONLY preview,owner 裁定 2026-09-24):各列回報自身 `frame(in: .named("projectTable"))`,
/// table 層收成 `rowFrames` 交給 `ProjectHoverController`;單一 `NSTrackingArea`(`HoverTrackingRepresentable`)的
/// pointer location 於同一座標空間 → `HoverZoneResolver` 只判**哪一列**含指標 → FSM。preview 純視覺、不參與 hover
/// 解析(故無 CardFrameKey / card zone / lastPointer)。取代先前 per-view `.onHover` 與 SwiftUI `.onContinuousHover`。
private struct RowFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 頁面內容身分(= `ProjectPageData` 的 projectPage 快取鍵投影):`(revision, pricingStamp, range)` 唯一決定頁面
/// 內容,故任何 tokens/cost/order/range 變動都改變它。ProjectTable 以此當 `.onChange` 鍵驅動 controller 重取
/// preview 切片(owner spike#3 fix #2:忠實身分,非弱 count fingerprint;不需給 ModelUsageSummary 加 Hashable)。
struct ProjectPageStamp: Equatable {
    let revision: UInt64
    let pricingStamp: UInt64
    let range: DateInterval
}

/// owner D3 — validity identity for RETAINED row geometry. `rowFrames` (viewport-space rects) is re-handed to the
/// controller on tab/appear re-activation to avoid a "dead until scroll" gap; but stale rects must never resolve a
/// pointer to the WRONG project. The retained geometry is valid ONLY while the page content identity (`pageStamp`)
/// AND the ordered project ids are unchanged. Viewport/layout identity (pure resize while inactive) is deliberately
/// NOT tracked here (would need viewport-size plumbing) — that residual is an accepted RECORD, self-corrected by the
/// first fresh `RowFramesKey` flush after re-activation. Principle: temporary no-hover > wrong-project hover.
private struct RowGeometryIdentity: Equatable {
    let pageStamp: ProjectPageStamp
    let orderedIDs: [String]
}

struct ProjectTable: View {
    let projects: [ProjectSummary]
    // Usage-M2b:per-project 模型明細(page-build 已建好、已依 §9.3 全序排好)。drill-down 互動**只讀此切片**
    // ——view 直接讀 `projectModels[key] ?? []`(與 `ProjectPageData.projectModelRows(forKey:)` seam 同 miss→空
    // 語意;該 seam 供 §10 no-lookup 測試),絕不重掃或呼叫 coordinator。**必填**(無預設):
    // 漏傳會編成空 drill-down 而 UsageCore 測試偵測不到(impl-xcheck grok/sol footgun),故強制在 call site 供給。
    let projectModels: [String: [ModelUsageSummary]]
    // Projects 是否為當前分頁。切離→controller 硬關;切回→controller 開新 session(NSTrackingArea 自然重接,
    // 無需 `.id`/epoch —— spike#2 的舊法)。修「切 tab 回來 hover 死、需切 range 才復活」。
    let isActive: Bool
    // owner spike#3 fix #2:頁面內容身分(revision/pricingStamp/range 投影)。任何 payload 變動(含 same
    // ids/counts 換料)都改變它 → 驅動 controller 重取 preview 切片,免展示舊數字。非弱 fingerprint、不需 Hashable。
    let pageStamp: ProjectPageStamp
    // Usage-M3 A1(owner re-architecture 2026-09-24,spike #2 FAILED):互動全部移到 `ProjectHoverController`
    // ——單一 owner 持有 row-only FSM + 唯一 output-only NSPanel + 列幾何;單一 `NSTrackingArea`
    // (`HoverTrackingRepresentable`)為唯一指標源(取代 SwiftUI `.onContinuousHover` 與失敗的 `.id(hoverEpoch)`
    // 重接)。preview 改由 screen 座標的 NSPanel 呈現(可超出 dashboard 視窗、只夾在 `NSScreen.visibleFrame`)。
    // 純件(HoverZoneResolver / AnchoredHoverModel / PanelPlacement)在 UsageCore 已單元測試;詳見 ProjectHoverPanel.swift。
    @StateObject private var controller = ProjectHoverController()
    @FocusState private var focusedRow: String?
    // spike#3 case B:保留最後已知的**非空**列幾何(viewport 空間)。切回 Projects 時顯式交回 controller,免得
    // 等 RowFramesKey 因 scroll/range 才重發(切離時列消失使 RowFramesKey 短暫收成空,是「切回 hover 死到 scroll
    // 才復活」的成因)。live 更新仍走 onPreferenceChange;此 @State 只快取最後非空值供 re-arm。
    @State private var rowFrames: [String: CGRect] = [:]
    // owner D3 — the page/order identity the retained `rowFrames` belong to; re-handed geometry is honored only
    // while this still matches the live `geometryIdentity` (else stale → wait for a fresh RowFramesKey flush).
    @State private var rowFramesIdentity: RowGeometryIdentity?
    @Environment(\.controlActiveState) private var controlActiveState
    private static let spaceName = "projectTable"

    /// owner D3 — current geometry validity identity (page content + ordered ids). See `RowGeometryIdentity`.
    private var geometryIdentity: RowGeometryIdentity {
        RowGeometryIdentity(pageStamp: pageStamp, orderedIDs: projects.map { $0.projectId })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if projects.isEmpty {
                Text("No usage in this range.")
                    .font(Theme.FontScale.secondaryInfo)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Share 欄整組配額(‰,一位小數;和恆 ≤100%,xcheck r1 twin)。
                        // 全集列 → 分母即列和。
                        let mille = ReportGenerator.rowShares(
                            rows: projects.map { $0.tokens.total },
                            periodTotal: projects.reduce(0) { $0 + $1.tokens.total }, scale: 1000)
                        ForEach(Array(projects.enumerated()), id: \.element.id) { index, p in
                            row(p, shareMille: mille[index])
                                .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
                        }
                    }
                }
                // 單一 NSTrackingArea 指標源覆蓋此 viewport(取代 `.onContinuousHover` 與失敗的 `.id(hoverEpoch)`
                // 重接)。座標空間放在 ScrollView(viewport)上 → 列以 viewport 空間回報 frame(RowFramesKey),與
                // tracker 的 flipped local 座標對齊;tracker hitTest→nil 不吃 click(列仍可 click-focus)。
                .coordinateSpace(name: Self.spaceName)
                // owner spike#3 hardening:tracker 明確填滿 viewport(避免 overlay 實際 bounds < viewport)。
                .overlay { HoverTrackingRepresentable(controller: controller).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        // 列幾何(viewport 空間)→ controller(唯一持有 FSM / panel / rowRects)。捲動/版面變動時 controller 內部
        // 作廢 pointer 擁有權(grace 關閉,focus 持有則留),不做 lastPointer 幾何重解(守 STOP 契約)。
        // spike#3 case B:忽略**空**的 flush(切離 Projects 時列消失會使 RowFramesKey 短暫收成空;若讓它清掉
        // retained 幾何,切回時 controller 拿到空 → hover 死)。非空才快取 + 轉交。可見列永遠非空(空專案走另一分支)。
        .onPreferenceChange(RowFramesKey.self) { newFrames in
            guard !newFrames.isEmpty else { return }
            rowFrames = newFrames
            rowFramesIdentity = geometryIdentity          // owner D3: stamp the identity these frames belong to
            controller.setRows(newFrames)
        }
        // 視窗級 Esc catcher(僅在 preview 顯示時存在):inert(key equivalent 仍觸發);action 走 controller.escape()。
        .background(alignment: .topLeading) {
            if controller.isShowing {
                Button("") { controller.escape() }
                    .keyboardShortcut(.cancelAction)
                    .focusable(false).allowsHitTesting(false).opacity(0).accessibilityHidden(true)
            }
        }
        // 整列 focus 變動 → controller(show 僅在 key window;non-key 不得 show)。
        .onChange(of: focusedRow) { oldValue, newValue in controller.setFocus(old: oldValue, new: newValue) }
        // key window 變動 → controller(失去 key → 硬關)。RECORD:`controlActiveState` 自 macOS 15 deprecated,本輪不換 API。
        .onChange(of: controlActiveState) { _, state in
            controller.setWindowActive(state == .key)
            // grok review r2:失去 key 由 hardClear 清 FSM focus;重獲 key 時 @FocusState 可能仍在某列(值未變 →
            // 無 onChange(focusedRow))→ 顯式重新灌回 controller,否則鍵盤 focus 的 preview 於 Cmd-Tab 來回後會死。
            if state == .key, let f = focusedRow { controller.setFocus(old: nil, new: f) }
        }
        // Projects 分頁 activate/deactivate 的**顯式**生命週期。切回時開新 session、**不重載資料**;NSTrackingArea 自然
        // 重接(不需 `.id`/epoch —— 那正是 spike #2 失敗的舊法)。先更新 panel 內容切片,再 activate。
        .onChange(of: isActive) { _, active in
            controller.setData(projectModels: projectModels, names: nameMap)
            controller.setActive(active)
            // spike#3 case B:切回時**顯式**把最後已知列幾何交回 controller(不等 RowFramesKey 因 scroll/range 才重發)。
            // grok review r2:切回時 @FocusState 若仍在某列,也重新灌回 FSM(setActive 已清 FSM focus)。
            if active {
                // owner D3: honor retained geometry only if its identity still matches (else wait for fresh flush)
                if rowFramesIdentity == geometryIdentity { controller.setRows(rowFrames) }
                if let f = focusedRow { controller.setFocus(old: nil, new: f) }
            }
        }
        // 資料變動(頁重載 / 換 range / refresh 同形換料)→ 以頁面內容身分為鍵更新 controller 供 panel 呈現的切片
        // (owner spike#3 fix #2:取代原本靠 project ids + model count 猜的弱 fingerprint)。
        .onChange(of: pageStamp) { _, _ in controller.setData(projectModels: projectModels, names: nameMap) }
        .onAppear {
            controller.setData(projectModels: projectModels, names: nameMap)
            controller.setWindowActive(controlActiveState == .key)
            controller.setActive(isActive)
            if isActive {
                if rowFramesIdentity == geometryIdentity { controller.setRows(rowFrames) }   // owner D3: identity-gated re-hand (spike#3 case B: appear-while-active)
                if let f = focusedRow { controller.setFocus(old: nil, new: f) }   // grok r2:重灌 @FocusState
            }
        }
        .onDisappear { controller.teardown() }
    }

    /// projectId → 已淨化顯示名(隱私:不外洩原始路徑),供 NSPanel 標題與 controller.setData 用。
    private var nameMap: [String: String] {
        Dictionary(projects.map { ($0.projectId, $0.projectName) }, uniquingKeysWith: { first, _ in first })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Project").frame(maxWidth: .infinity, alignment: .leading)
            Text("Tokens").frame(width: 76, alignment: .trailing)
            Text("Est. cost").frame(width: 86, alignment: .trailing)
            Text("Agents").frame(width: 130, alignment: .leading)
            Text("Top model").frame(width: 150, alignment: .leading)
            Text("Last active").frame(width: 78, alignment: .trailing)
            Text("Share").frame(width: 52, alignment: .trailing)
        }
        .font(Theme.FontScale.tableHeader)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func row(_ p: ProjectSummary, shareMille: Int) -> some View {
        HStack(spacing: 8) {
            // 隱私:不在 tooltip 露出完整本機路徑(與報告的 redact 姿態一致)
            Text(p.projectName).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(tk(p.tokens.total)).monospacedDigit().frame(width: 76, alignment: .trailing)
            Text(costText(p.cost)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 86, alignment: .trailing)
            // A8:Agents 欄用短名(Claude, Codex, Grok)不換行;全名在 .help。
            Text(p.providers.map { ProviderBrands.brand(for: $0).shortName }.joined(separator: ", "))
                .lineLimit(1)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 130, alignment: .leading)
                .help(p.providers.map { ProviderBrands.brand(for: $0).displayName }.joined(separator: ", "))
            // P-B co-fix(§16):topModel 走封閉 attributedModelLabel(路徑形 → basename;nil → "—";
            // "" → "empty model id"),與 HTML 報告的 redact 姿態一致;絕不外洩原始路徑形 modelId。
            Text(PrivacyRedaction.attributedModelLabel(modelId: p.topModel)).lineLimit(1)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 150, alignment: .leading)
            Text(timeAgo(p.lastActive))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 78, alignment: .trailing)
            Text(ReportGenerator.milleLabel(shareMille, nonZero: p.tokens.total > 0)).monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 52, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())                       // 全列命中(click-focus / focus ring 覆整列)
        .focusable()                                     // 鍵盤可達(整列 = focus anchor;非 pointer-only)
        .focused($focusedRow, equals: p.projectId)
        .onDisappear {   // scroll-away / LazyVStack recycle:同步告知 controller(移除殘留 rect + FSM 和解),並清實際 @FocusState
            controller.rowDisappeared(p.projectId)
            if focusedRow == p.projectId { focusedRow = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.projectName), \(tk(p.tokens.total)) tokens")
        .accessibilityHint("Shows this project's model breakdown")   // 承接被移除 chevron 的 a11y
        // 列回報自身 frame(同 "projectTable" 座標空間)→ rowFrames;NSTrackingArea 的 pointer location 據此判 zone。
        // 不再用 per-row .onHover / anchorPreference —— 單一 `NSTrackingArea`(HoverTrackingRepresentable)為唯一指標源。
        .background(GeometryReader { g in
            Color.clear.preference(key: RowFramesKey.self,
                                   value: [p.projectId: g.frame(in: .named(Self.spaceName))])
        })
    }
}

// MARK: - Usage-M2b:project → provider → model drill-down popover(§9.3)
// 平面清單(跨 provider),**可見 Provider 欄**;欄 = Provider | Model | In | Out | Cache | Total | Cost | Share;
// share 為**組內(專案內)**配額(D2);top 12 於自身 bounded 捲動區可見、其餘捲動揭露(「+K more」);
// 鍵盤可達、Esc 關閉;模型名走封閉 modelLabel(路徑形 → basename;不外洩原始 id / 專案路徑)。
struct ModelDrilldownPopover: View {
    let projectName: String
    let rows: [ModelUsageSummary]      // 已依 §9.3 全序 (−total, providerId, unattributedLast, exactModelId) 排好

    private let visibleCap = 12        // top 12 可見(n10);其餘於 bounded 捲動區揭露

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Usage-M3 A1:標題列 —— 無 Done/Close 鈕(hover-first)。preview 本身**不**處理 dismiss:指標離開
            // 所有列由 table 層單一 `NSTrackingArea` 指標源經 grace 關閉;Esc 由 table 層 window 級 catcher 處理。
            HStack(spacing: 8) {
                Text(projectName).font(Theme.FontScale.cardTitle).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            Divider()
            header
            Divider()
            if rows.isEmpty {
                Text("No model usage in this project.")
                    .font(Theme.FontScale.secondaryInfo)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                // share = 組內(專案內)配額(和恆 ≤100%);全集列 → 分母即列和(§4/D2)。
                let mille = ReportGenerator.rowShares(
                    rows: rows.map { $0.tokens.total },
                    periodTotal: rows.reduce(0) { $0 + $1.tokens.total }, scale: 1000)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, m in
                            row(m, shareMille: mille[index])
                                .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
                        }
                        // 「+K more」footer 於 bounded 捲動區**內**、清單尾端(§9.3:scroll-to-reveal inside the
                        // scroll area;impl-xcheck luna/sol —— 不再固定於捲動區外)。
                        if rows.count > visibleCap {
                            Text("+\(rows.count - visibleCap) more — scroll")
                                .font(Theme.FontScale.secondaryInfo)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 5)
                        }
                    }
                }
                .frame(maxHeight: CGFloat(visibleCap) * 26)   // ~top-12 可見;其餘(含 footer)於捲動區內揭露
            }
        }
        .frame(width: 760)             // bounded 寬度(絕不覆蓋整窗);Model 欄得 ~212pt 可讀(impl-xcheck sol)
        .padding(.bottom, 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Provider").frame(width: 78, alignment: .leading)
            Text("Model").frame(maxWidth: .infinity, alignment: .leading)
            Text("In").frame(width: 62, alignment: .trailing)
                .help("Input = fresh (non-cached) input tokens; cached context is shown under Cache.")   // A2 chrome-only
            Text("Out").frame(width: 62, alignment: .trailing)
            Text("Cache").frame(width: 62, alignment: .trailing)
            Text("Total").frame(width: 70, alignment: .trailing)
            Text("Cost").frame(width: 86, alignment: .trailing)
            Text("Share").frame(width: 48, alignment: .trailing)
        }
        .font(Theme.FontScale.tableHeader)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func row(_ m: ModelUsageSummary, shareMille: Int) -> some View {
        // 模型名走封閉 modelLabel(路徑形 → basename;.unattributed → "unattributed";"" → "empty model id")。
        let label = PrivacyRedaction.modelLabel(attribution: m.attribution)
        let brand = ProviderBrands.brand(for: m.providerId)
        let cost = costDisplay(m.cost)
        return HStack(spacing: 8) {
            // 可見 Provider 欄(r4-B):跨 provider 平面清單中,同模型/未歸屬列以此區辨,非只在排序鍵/VoiceOver。
            Text(brand.shortName).lineLimit(1).foregroundStyle(Theme.textSecondary)
                .frame(width: 78, alignment: .leading).help(brand.displayName)
            Text(label).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading).help(label)
            Text(tk(m.tokens.input)).monospacedDigit().frame(width: 62, alignment: .trailing)
            Text(tk(m.tokens.output)).monospacedDigit().frame(width: 62, alignment: .trailing)
            Text(tk(m.tokens.cacheRead + m.tokens.cacheWrite)).monospacedDigit().frame(width: 62, alignment: .trailing)
            Text(tk(m.tokens.total)).monospacedDigit().frame(width: 70, alignment: .trailing)
            // §7:cost 缺失絕不像 $0(costDisplay.value 已保證);caption(未計價量 / opencode-reported 出處)於 .help。
            Text(cost.value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 86, alignment: .trailing).help(cost.caption ?? "")
            Text(ReportGenerator.milleLabel(shareMille, nonZero: m.tokens.total > 0)).monospacedDigit()
                .foregroundStyle(Theme.textSecondary).frame(width: 48, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        // VoiceOver(§9.3):「<provider> <model>: <total> tokens, <cost>」
        .accessibilityLabel("\(brand.displayName) \(label): \(m.tokens.total) tokens, \(cost.value)")
    }
}

// MARK: - Usage-M2a：global provider-scoped「By model」表格(§9.2)
// 消費已依 §2 全序建好的 page.models(providers 連續、組內排序皆決定性);純顯示、零重掃、
// 於自身容器內捲動(n12);無 provider-limit %、無 sessions。
struct ByModelTable: View {
    let models: [ModelUsageSummary]

    // provider-連續分組(保留建構器的決定性順序)。
    private var groups: [(provider: String, rows: [ModelUsageSummary])] {
        var out: [(provider: String, rows: [ModelUsageSummary])] = []
        for m in models {
            if !out.isEmpty, out[out.count - 1].provider == m.providerId {
                out[out.count - 1].rows.append(m)
            } else {
                out.append((provider: m.providerId, rows: [m]))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if models.isEmpty {
                Text("No model usage in this range.")
                    .font(Theme.FontScale.secondaryInfo)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.provider) { group in
                            groupSection(group)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Model").frame(maxWidth: .infinity, alignment: .leading)
            Text("Input").frame(width: 72, alignment: .trailing)
            Text("Output").frame(width: 72, alignment: .trailing)
            Text("Cache").frame(width: 72, alignment: .trailing)
            Text("Total").frame(width: 78, alignment: .trailing)
            Text("Est. cost").frame(width: 86, alignment: .trailing)
            Text("Share").frame(width: 52, alignment: .trailing)
        }
        .font(Theme.FontScale.tableHeader)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // 每個 provider 一段:表頭下的 provider 小標 + 該組列;share 為**組內**配額(§2/D2:within-provider)。
    private func groupSection(_ group: (provider: String, rows: [ModelUsageSummary])) -> some View {
        let mille = ReportGenerator.rowShares(
            rows: group.rows.map { $0.tokens.total },
            periodTotal: group.rows.reduce(0) { $0 + $1.tokens.total }, scale: 1000)
        return VStack(alignment: .leading, spacing: 0) {
            Text(ProviderBrands.brand(for: group.provider).displayName)
                .font(Theme.FontScale.tableHeader)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 9)
                .padding(.bottom, 2)
            ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, m in
                row(m, shareMille: mille[index])
                    .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
            }
        }
    }

    private func row(_ m: ModelUsageSummary, shareMille: Int) -> some View {
        // 模型名走封閉 modelLabel(路徑形 → basename;.unattributed → "unattributed";"" → "empty model id")。
        let label = PrivacyRedaction.modelLabel(attribution: m.attribution)
        let cost = costDisplay(m.cost)   // value + caption(未計價量 / opencode-reported 出處)
        return HStack(spacing: 8) {
            Text(label).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(label)
            Text(tk(m.tokens.input)).monospacedDigit().frame(width: 72, alignment: .trailing)
            Text(tk(m.tokens.output)).monospacedDigit().frame(width: 72, alignment: .trailing)
            Text(tk(m.tokens.cacheRead + m.tokens.cacheWrite)).monospacedDigit().frame(width: 72, alignment: .trailing)
            Text(tk(m.tokens.total)).monospacedDigit().frame(width: 78, alignment: .trailing)
            // §7:cost 缺失絕不像 $0(costDisplay.value 已保證);caption(未計價量 + opencode-reported 出處)
            // 在 dense 表格以 .help 呈現,不遺失 provenance(impl-xcheck r2 luna+sol)。
            Text(cost.value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 86, alignment: .trailing)
                .help(cost.caption ?? "")
            Text(ReportGenerator.milleLabel(shareMille, nonZero: m.tokens.total > 0)).monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 52, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
