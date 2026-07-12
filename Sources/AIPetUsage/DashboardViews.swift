import SwiftUI
import UsageCore
import PetCore

// MARK: - 共用格式化

func tk(_ n: Int) -> String { ReportGenerator.fmtTokens(n) }

/// 成本顯示規則(review #7):定價缺失時不得看起來像「花費 $0」。
/// - 全部/幾乎全部未計價 → 「Pricing unavailable」+ 未計價量
/// - 部分未計價 → 「$X.XX+」,caption 說明 + 的含義
func costDisplay(_ c: CostResult) -> (value: String, caption: String?) {
    if c.unknownModelTokens > 0 && c.knownUSD < 0.005 {
        return ("Pricing unavailable", "\(tk(c.unknownModelTokens)) tokens unpriced")
    }
    if c.unknownModelTokens > 0 {
        return (String(format: "$%.2f+", c.knownUSD),
                "+ means \(tk(c.unknownModelTokens)) tokens are unpriced")
    }
    return (String(format: "$%.2f", c.knownUSD), c.isEstimated ? "cache rates estimated" : nil)
}

func costText(_ c: CostResult) -> String { costDisplay(c).value }

func countdown(to date: Date?, now: Date = Date()) -> String {
    guard let date else { return "—" }
    let s = date.timeIntervalSince(now)
    if s <= 0 { return "now" }
    let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
    if h > 48 { return "\(h / 24)d \(h % 24)h" }
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
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
            ProjectsView().tabItem { Label("Projects", systemImage: "folder") }.tag(DashboardTab.projects)
            TrendsView().tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }.tag(DashboardTab.trends)
        }
        .frame(minWidth: 860, minHeight: 600)
        .toolbar {
            ToolbarItemGroup {
                if let last = model.dashboard.lastRefreshAt {
                    Text("Refreshed \(timeAgo(last))")
                        .font(Theme.FontScale.secondaryInfo)
                        .foregroundStyle(Theme.textSecondary)
                }
                Button {
                    Task { await model.refreshNow() }
                } label: {
                    if model.refreshing { ProgressView().controlSize(.small) }
                    else { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .keyboardShortcut("r")

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
        }
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
            Text("in \(pctLabel(input)) · out \(pctLabel(output)) · cache \(pctLabel(cache))")
                .font(Theme.FontScale.secondaryInfo)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func pctLabel(_ v: Double) -> String {
        v < 0.005 && v > 0 ? "<1%" : "\(Int((v * 100).rounded()))%"
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

struct LimitBar: View {
    @Environment(\.openSettings) private var openSettings
    let title: String
    let window: LimitWindowState
    let warn: Double
    var danger: Double = 99.5
    var showBudgetAffordance = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(valueText).font(.caption).monospacedDigit().foregroundStyle(Theme.textPrimary)
            }
            GaugeBar(percent: window.usedPercent ?? 0, warn: warn, danger: danger)
                .frame(height: 6)
                .opacity(window.usedPercent == nil ? 0.25 : 1)
            HStack {
                Text(resetText).font(Theme.FontScale.secondaryInfo).foregroundStyle(Theme.textSecondary)
                Spacer()
                if window.corrected {
                    Text("corrected").font(.caption2).foregroundStyle(.orange)
                }
                Text(window.confidence.rawValue).font(.caption2).foregroundStyle(Theme.textMuted)
            }
            // review #3:百分比缺失時,原因與解法直接放在卡片裡
            if window.usedPercent == nil, showBudgetAffordance {
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
    }

    private var valueText: String {
        if let p = window.usedPercent {
            var s = String(format: "%.1f%%", p)
            if let t = window.usedTokens, let b = window.budgetTokens {
                s += "  (\(tk(t))/\(tk(b)))"
            }
            return s
        }
        if let t = window.usedTokens { return "\(tk(t)) tokens · — %" }
        return "no data"
    }

    private var resetText: String {
        if let reset = window.resetAt { return "resets in \(countdown(to: reset))" }
        if window.windowMinutes >= 10080, window.usedTokens != nil { return "rolling 7-day" }
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

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Y 軸刻度
            VStack(alignment: .trailing) {
                Text(tk(niceMax))
                Spacer()
                Text(tk(niceMax / 2))
                Spacer()
                Text("0")
            }
            .font(Theme.FontScale.micro)
            .foregroundStyle(Theme.textMuted)
            .frame(width: 34)
            .padding(.bottom, 12)

            GeometryReader { geo in
                let barArea = geo.size.height - 12
                let n = max(1, slots.count)
                let slotW = geo.size.width / CGFloat(n)
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
                        ForEach(slots, id: \.self) { hour in
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
                                Text(hour % 6 == 0 ? "\(hour)" : " ")
                                    .font(Theme.FontScale.micro)
                                    .foregroundStyle(Theme.textMuted)
                                    .frame(height: 10)
                            }
                            .frame(maxWidth: .infinity, alignment: .bottom)
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
                                 caption: "Lv.\(model.petState.level) · fullness \(Int(model.petState.hunger))%")
                            .help(PetInfo.tooltip)
                    }
                }

                Text("Coding agents").font(Theme.FontScale.cardTitle)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                    ForEach(model.orderedSnapshots) { snap in
                        AgentCard(snapshot: snap,
                                  limit: dash.limitStates.first { $0.providerId == snap.providerId })
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
                            ForEach(dash.topProjects.prefix(6)) { p in
                                ProjectShareRow(project: p)
                            }
                        }
                    }
                    .frame(width: 320)
                }

                if !dash.dataQuality.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Data quality").font(Theme.FontScale.cardTitle)
                        ForEach(dash.dataQuality, id: \.self) { note in
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
            return String(format: "≈ $%.2f/h", dash.burnCostPerHour)
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
                Text("Everything is read locally — nothing is uploaded.")
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
struct ProjectShareRow: View {
    let project: ProjectSummary

    var body: some View {
        HStack {
            Text(project.projectName).lineLimit(1).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(tk(project.tokens.total)).monospacedDigit().foregroundStyle(Theme.textSecondary)
            Text(String(format: "%.0f%%", project.shareOfPeriod * 100))
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

    var body: some View {
        let brand = ProviderBrands.brand(for: snapshot.providerId, displayName: snapshot.displayName)
        VStack(alignment: .leading, spacing: 8) {
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
            HStack(spacing: 14) {
                metric("today", tk((snapshot.tokenInput ?? 0) + (snapshot.tokenOutput ?? 0) + (snapshot.tokenCache ?? 0)))
                metric("5h window", snapshot.sessionUsagePercent.map { String(format: "%.0f%%", $0) } ?? "— %")
                metric("weekly", snapshot.weeklyUsagePercent.map { String(format: "%.0f%%", $0) } ?? "— %")
            }
            if snapshot.sessionUsagePercent == nil, snapshot.providerId == "claude-code" {
                Button("Set estimated budget…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
            // A3:reset 行恆渲染(無資料顯示 —)→ 三張卡行數一致、等高不跳動。
            Text(snapshot.resetAt.map { "5h resets in \(countdown(to: $0))" } ?? "5h resets: —")
                .font(Theme.FontScale.secondaryInfo)
                .foregroundStyle(Theme.textSecondary)
            if let err = snapshot.errorMessage {
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
            Text("in \(tk(snapshot.tokenInput ?? 0)) · out \(tk(snapshot.tokenOutput ?? 0)) · cache \(tk(snapshot.tokenCache ?? 0))")
                .font(Theme.FontScale.secondaryInfo)
                .foregroundStyle(Theme.textSecondary)
            Text("data: \(timeAgo(snapshot.updatedAt))")
                .font(Theme.FontScale.secondaryInfo)
                .foregroundStyle(Theme.textMuted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.orderedLimitStates) { limit in
                    LimitRow(limit: limit,
                             snapshot: dash.snapshots.first { $0.providerId == limit.providerId },
                             warn: model.settings.core.warnThresholdPercent,
                             danger: model.settings.core.dangerThresholdPercent)
                }

                if dash.limitStates.first(where: { $0.providerId == "claude-code" })?.fiveHour.usedPercent == nil {
                    Label("Claude Code official limits appear automatically when a statusline hook saves Claude Code's payload locally (see Scripts/claude-statusline-hook.sh). Without it, set an estimated token budget in Settings → Limits.",
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
            HStack(alignment: .top, spacing: 24) {
                LimitBar(title: "5-hour window", window: limit.fiveHour, warn: warn, danger: danger,
                         showBudgetAffordance: limit.providerId == "claude-code")
                LimitBar(title: "Weekly window", window: limit.weekly, warn: warn, danger: danger,
                         showBudgetAffordance: limit.providerId == "claude-code")
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
}

// MARK: - Page 3: Projects(自繪表格:載入後不出現空白填充列,review #6)

struct ProjectsView: View {
    @Environment(AppModel.self) private var model

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
                    DatePicker("From", selection: $model.customStart, displayedComponents: .date)
                    DatePicker("To", selection: $model.customEnd, displayedComponents: .date)
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

                ProjectTable(projects: page.projects)
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

struct ProjectTable: View {
    let projects: [ProjectSummary]

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
                        ForEach(Array(projects.enumerated()), id: \.element.id) { index, p in
                            row(p)
                                .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))
                        }
                    }
                }
            }
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
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

    private func row(_ p: ProjectSummary) -> some View {
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
            Text(p.topModel ?? "—").lineLimit(1)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 150, alignment: .leading)
            Text(timeAgo(p.lastActive))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 78, alignment: .trailing)
            Text(String(format: "%.1f%%", p.shareOfPeriod * 100)).monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 52, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
