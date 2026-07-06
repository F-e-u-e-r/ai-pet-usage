import Foundation
import UsageCore

/// 心情引擎:把 DashboardState + 寵物狀態濃縮成單一 mood 與動畫強度。
/// 寵物只消費正規化資料,完全不知道 provider 細節(規格要求)。
public enum MoodEngine {

    public struct Result: Equatable, Sendable {
        public var mood: PetMood
        /// 動畫速度倍率(1 = 平常;燃燒率高 → 更快、更躁動)。
        public var animationSpeed: Double
        /// 一句話的狀態摘要(泡泡與報告用)。
        public var summary: String

        public init(mood: PetMood, animationSpeed: Double, summary: String) {
            self.mood = mood
            self.animationSpeed = animationSpeed
            self.summary = summary
        }
    }

    public static func evaluate(dashboard: DashboardState, pet: PetStateData,
                                warnThreshold: Double, now: Date = Date()) -> Result {
        let limits = dashboard.limitStates

        let fivePercents = limits.compactMap { $0.fiveHour.usedPercent }
        let weeklyPercents = limits.compactMap { $0.weekly.usedPercent }
        let worstFive = fivePercents.max()
        let worstWeekly = weeklyPercents.max()
        let anyExhausted = limits.contains { $0.warning == .exhausted }
        let anyStale = dashboard.snapshots.contains { $0.status == .stale || $0.status == .error }
        let allNoData = !dashboard.snapshots.isEmpty && dashboard.snapshots.allSatisfy {
            $0.status == .noData || $0.status == .unavailable
        }
        let lastEventAt = limits.compactMap(\.lastEventAt).max()
        let soonestExhaustion = limits.compactMap(\.projectedExhaustionAt).min()

        // 動畫強度:預計 90 分鐘內耗盡 → 焦躁加速
        var speed = 1.0
        if let soonest = soonestExhaustion {
            let minutes = soonest.timeIntervalSince(now) / 60
            if minutes < 30 { speed = 2.0 }
            else if minutes < 90 { speed = 1.5 }
        }

        // 每家 provider 各自的 5h 百分比都列出(使用者要求同時看到 Claude 與 Codex)。
        let providerParts = limits.map { st -> String in
            let code = shortProviderCode(st.providerId)
            if let p = st.fiveHour.usedPercent { return "\(code) \(Int(p))%" }
            return "\(code) —"
        }
        let head = providerParts.isEmpty ? "no providers" : providerParts.joined(separator: " · ")
        let summary = "\(head) · burn \(ReportGenerator.fmtTokens(Int(dashboard.burnRateTokensPerHour)))/h"

        // 優先序(高 → 低)
        if let until = pet.eatingUntil, until > now {
            return Result(mood: .eating, animationSpeed: 1.2, summary: summary)
        }
        if let until = pet.celebrationUntil, until > now {
            return Result(mood: .celebration, animationSpeed: 1.6, summary: "Quota reset! " + summary)
        }
        if anyExhausted {
            return Result(mood: .exhausted, animationSpeed: 0.4, summary: summary)
        }
        if let worst = worstFive, worst >= warnThreshold {
            return Result(mood: .warning, animationSpeed: max(speed, 1.5), summary: summary)
        }
        if let weekly = worstWeekly, weekly >= warnThreshold {
            return Result(mood: .tired, animationSpeed: 0.7, summary: summary)
        }
        if allNoData {
            return Result(mood: .confused, animationSpeed: 0.8, summary: "No usage data yet. " + summary)
        }
        if anyStale {
            return Result(mood: .confused, animationSpeed: 0.8, summary: "Data looks stale. " + summary)
        }
        let idleMinutes = lastEventAt.map { now.timeIntervalSince($0) / 60 } ?? .infinity
        if idleMinutes > 45 {
            return Result(mood: .sleeping, animationSpeed: 0.3, summary: summary)
        }
        if pet.hunger < 30 {
            return Result(mood: .hungry, animationSpeed: 1.1, summary: "Hungry! " + summary)
        }
        if let until = pet.happyUntil, until > now {
            return Result(mood: .happy, animationSpeed: 1.2, summary: summary)
        }
        if idleMinutes <= 10 {
            return Result(mood: .focused, animationSpeed: speed, summary: summary)
        }
        return Result(mood: .idle, animationSpeed: min(speed, 1.2), summary: summary)
    }

    /// mood → 疊加在寵物本體旁的小徽章。
    public static func badge(for mood: PetMood) -> String? {
        switch mood {
        case .idle: return nil
        case .focused: return "⌨️"
        case .hungry: return "🍽️"
        case .eating: return nil // 顯示食物本身
        case .happy: return "❤️"
        case .tired: return "😪"
        case .warning: return "⚠️"
        case .exhausted: return "🪫"
        case .sleeping: return "💤"
        case .celebration: return "🎉"
        case .confused: return "❓"
        }
    }
}
