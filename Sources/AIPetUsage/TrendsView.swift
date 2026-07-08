import SwiftUI
import UsageCore

/// Trends 分頁:近 7 / 30 / 90 天的每日用量曲線、週對比、使用連續天數與日曆熱圖。
/// 純本機、零新依賴;資料由 AppModel.trends(UsageCoordinator.trendsData)提供。
struct TrendsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Range", selection: $model.trendsRangeDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)

                if let trends = model.trends, !trends.daily.isEmpty {
                    HStack(spacing: 12) {
                        StatTile(title: "Current streak", value: dayCountLabel(trends.streak.current))
                        StatTile(title: "Longest streak", value: dayCountLabel(trends.streak.longest))
                        StatTile(title: "This week",
                                 value: tokenLabel(trends.thisWeekTokens),
                                 caption: weekDeltaCaption(trends))
                    }

                    section("Daily tokens (\(trends.rangeDays) days)") {
                        DailyBarChart(daily: trends.daily, startDay: trends.startDay, endDay: trends.endDay)
                            .frame(height: 150)
                    }

                    section("Activity heatmap") {
                        UsageHeatmap(daily: trends.daily, startDay: trends.startDay, endDay: trends.endDay)
                    }
                } else if model.trends != nil {
                    ContentUnavailableView("No usage in this range",
                                           systemImage: "chart.xyaxis.line",
                                           description: Text("Run a Claude Code or Codex session, then Refresh."))
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    ProgressView("Gathering usage…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(20)
        }
        .task(id: model.trendsRangeDays) { await model.reloadTrends() }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.FontScale.cardTitle).foregroundStyle(Theme.textPrimary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func dayCountLabel(_ n: Int) -> String { "\(n) day\(n == 1 ? "" : "s")" }

    private func weekDeltaCaption(_ t: TrendsData) -> String? {
        guard t.lastWeekTokens > 0 else { return t.thisWeekTokens > 0 ? "new activity" : nil }
        let delta = Double(t.thisWeekTokens - t.lastWeekTokens) / Double(t.lastWeekTokens) * 100
        let rounded = Int(delta.rounded())
        if rounded == 0 { return "≈ same as last week" }
        return "\(rounded > 0 ? "▲" : "▼") \(abs(rounded))% vs last week"
    }
}

/// token 精簡格式(1.2M / 3.4K / 950)。
func tokenLabel(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}

// MARK: - 每日 token bar chart(補零到完整日期範圍)

struct DailyBarChart: View {
    let daily: [DayBucket]
    let startDay: Date
    let endDay: Date
    private let calendar = Calendar.current

    var body: some View {
        let values = dailyValues()
        let maxV = max(1, values.max() ?? 1)
        GeometryReader { geo in
            let n = max(1, values.count)
            let gap: CGFloat = values.count > 45 ? 1 : 2
            let barW = max(1, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(v > 0 ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.12))
                        .frame(width: barW,
                               height: max(v > 0 ? 2 : 1, geo.size.height * CGFloat(v) / CGFloat(maxV)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func dailyValues() -> [Int] {
        let byDay = Dictionary(daily.map { ($0.day, $0.tokens) }, uniquingKeysWith: +)
        return TrendCalendar.days(from: startDay, to: endDay, calendar: calendar).map { byDay[$0] ?? 0 }
    }
}

// MARK: - 日曆熱圖(GitHub 貢獻圖風格;週為欄、週幾為列)

struct UsageHeatmap: View {
    let daily: [DayBucket]
    let startDay: Date
    let endDay: Date
    private let calendar = Calendar.current
    private let cell: CGFloat = 12
    private let gap: CGFloat = 3

    var body: some View {
        let byDay = Dictionary(daily.map { ($0.day, $0.tokens) }, uniquingKeysWith: +)
        let maxV = daily.map(\.tokens).max() ?? 0
        let weeks = weekColumns()
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { row in
                                cellView(week[row], byDay: byDay, maxV: maxV)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            legend()
        }
    }

    private func cellView(_ day: Date?, byDay: [Date: Int], maxV: Int) -> some View {
        let tokens = day.flatMap { byDay[$0] } ?? 0
        let level = day == nil ? -1 : heatLevel(tokens, maxV: maxV)
        return RoundedRectangle(cornerRadius: 2)
            .fill(Self.color(for: level))
            .frame(width: cell, height: cell)
            .help(day.map { "\(Self.dayFormatter.string(from: $0)) · \(tokenLabel(tokens)) tokens" } ?? "")
    }

    private func legend() -> some View {
        HStack(spacing: gap) {
            Text("Less").font(Theme.FontScale.micro).foregroundStyle(Theme.textMuted)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2).fill(Self.color(for: level)).frame(width: cell, height: cell)
            }
            Text("More").font(Theme.FontScale.micro).foregroundStyle(Theme.textMuted)
        }
    }

    private func heatLevel(_ tokens: Int, maxV: Int) -> Int {
        guard tokens > 0, maxV > 0 else { return 0 }
        let ratio = Double(tokens) / Double(maxV)
        if ratio > 0.66 { return 4 }
        if ratio > 0.33 { return 3 }
        if ratio > 0.10 { return 2 }
        return 1
    }

    private static func color(for level: Int) -> Color {
        switch level {
        case -1: return .clear                          // 範圍外的補齊格
        case 0: return Color.secondary.opacity(0.14)    // 有日、無用量
        case 1: return Color.accentColor.opacity(0.30)
        case 2: return Color.accentColor.opacity(0.50)
        case 3: return Color.accentColor.opacity(0.72)
        default: return Color.accentColor.opacity(0.95)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// 以週為欄:每欄 7 格(週幾為列),前導/尾隨用 nil 補齊。
    private func weekColumns() -> [[Date?]] {
        let startWeekday = calendar.component(.weekday, from: startDay)
        let leadingPad = (startWeekday - calendar.firstWeekday + 7) % 7
        var weeks: [[Date?]] = []
        var current: [Date?] = Array(repeating: nil, count: leadingPad)
        for day in TrendCalendar.days(from: startDay, to: endDay, calendar: calendar) {
            current.append(day)
            if current.count == 7 { weeks.append(current); current = [] }
        }
        if !current.isEmpty {
            while current.count < 7 { current.append(nil) }
            weeks.append(current)
        }
        return weeks
    }
}

// MARK: - 日期範圍工具

enum TrendCalendar {
    /// [from, to] 之間(含端點)每一個本地日午夜的陣列。
    static func days(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        var out: [Date] = []
        var d = start
        while d <= end {
            out.append(d)
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return out
    }
}
