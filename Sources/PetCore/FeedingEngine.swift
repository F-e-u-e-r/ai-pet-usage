import Foundation
import UsageCore

/// 餵食與 XP 引擎。設計原則(規格):獎勵有用的工作,不獎勵揮霍 token——
/// XP 有每日上限、點心券來自實際工作時間、健康用量另給加成。
public final class FeedingEngine {
    public private(set) var state: PetStateData
    private let stateURL: URL?

    /// 飢餓衰減:每小時 -9(約 8 小時從 75 → 0)。
    public static let hungerDecayPerHour: Double = 9
    /// 每日 token XP 上限(1k tokens = 1 XP,上限 200)。
    public static let dailyTokenXPCap: Double = 200
    /// 健康加成:昨日全日未觸警戒閾值 +50 XP。
    public static let healthyDayBonus: Double = 50
    /// 每 25 分鐘有活動 = 1 張點心券,每日上限 6 張。
    public static let minutesPerTreat: Double = 25
    public static let dailyTreatCap = 6
    public static let dailyKibbleCap = 4

    public init(stateURL: URL?, now: Date = Date()) {
        self.stateURL = stateURL
        if let stateURL, let loaded = AtomicJSON.read(PetStateData.self, from: stateURL) {
            state = loaded
        } else {
            state = PetStateData(now: now)
        }
    }

    private func save() {
        guard let stateURL else { return }
        try? AtomicJSON.write(state, to: stateURL)
    }

    /// 每次刷新呼叫:衰減飢餓、日界輪替、依 token 活動累積 XP。
    /// 日界輪替時,若前一日從未進入 warning/exhausted 則發放健康日加成。
    public func tick(now: Date = Date(), activeMinutesToday: Double, tokensToday: Int) {
        // 日界輪替
        let todayKey = PetStateData.dayKey(for: now)
        if todayKey != state.dayKey {
            if !state.warningSeenToday, state.healthyBonusAwardedFor != state.dayKey {
                state.xp += Self.healthyDayBonus
                state.healthyBonusAwardedFor = state.dayKey
            }
            state.dayKey = todayKey
            state.treatsSpentToday = 0
            state.kibbleUsedToday = 0
            state.xpFromTokensToday = 0
            state.warningSeenToday = false
        }

        // 飢餓衰減
        let hours = max(0, now.timeIntervalSince(state.lastDecayAt) / 3600)
        if hours > 0 {
            state.hunger = max(0, state.hunger - hours * Self.hungerDecayPerHour)
            state.lastDecayAt = now
        }

        // token XP(封頂)
        let target = min(Self.dailyTokenXPCap, Double(tokensToday) / 1000)
        if target > state.xpFromTokensToday {
            state.xp += target - state.xpFromTokensToday
            state.xpFromTokensToday = target
        }

        save()
    }

    /// 尚可用的點心券 = 今日工作時間換算 − 已花費。
    public func treatsAvailable(activeMinutesToday: Double) -> Int {
        let earned = min(Self.dailyTreatCap, Int(activeMinutesToday / Self.minutesPerTreat))
        return max(0, earned - state.treatsSpentToday)
    }

    public enum FeedResult: Equatable {
        case ok
        case notHungry
        case noTreats
        case kibbleLimitReached
    }

    @discardableResult
    public func feed(_ food: FoodItem, activeMinutesToday: Double, now: Date = Date()) -> FeedResult {
        if state.hunger > 92 { return .notHungry }
        if food.treatCost == 0 {
            guard state.kibbleUsedToday < Self.dailyKibbleCap else { return .kibbleLimitReached }
            state.kibbleUsedToday += 1
        } else {
            guard treatsAvailable(activeMinutesToday: activeMinutesToday) >= food.treatCost else { return .noTreats }
            state.treatsSpentToday += food.treatCost
        }
        state.hunger = min(100, state.hunger + food.satiety)
        state.lastFedAt = now
        state.eatingUntil = now.addingTimeInterval(6)
        state.eatingFoodId = food.id
        state.happyUntil = now.addingTimeInterval(120)
        state.totalFeeds += 1
        state.xp += 2 // 照顧寵物本身給少量 XP
        save()
        return .ok
    }

    public func celebrate(until: Date, providerId: String? = nil, window: String? = nil,
                          estimated: Bool = false) {
        state.celebrationUntil = until
        state.celebrationProviderId = providerId
        state.celebrationWindow = window
        state.celebrationEstimated = estimated
        save()
    }

    /// 記錄今日曾進入 warning/exhausted(取消當日健康加成資格)。
    public func noteWarningSeen() {
        guard !state.warningSeenToday else { return }
        state.warningSeenToday = true
        save()
    }

    /// 測試專用:直接設定飢餓值。
    public func _test_setHunger(_ value: Double) {
        state.hunger = value
    }
}
