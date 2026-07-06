import Foundation

public enum PetSpecies: String, Codable, CaseIterable, Sendable {
    case dog
    case cat

    public var displayName: String { self == .dog ? "Golden Retriever" : "Black Cat" }
}

/// 規格要求的十種狀態。
public enum PetMood: String, Codable, Sendable {
    case idle
    case focused
    case hungry
    case eating
    case happy
    case tired
    case warning
    case exhausted
    case sleeping
    case celebration
    case confused
}

public struct FoodItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let emoji: String
    /// 需要的點心券(以有效工作時間賺得);0 = 免費(每日有次數上限)。
    public let treatCost: Int
    public let satiety: Double

    public init(id: String, name: String, emoji: String, treatCost: Int, satiety: Double) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.treatCost = treatCost
        self.satiety = satiety
    }

    public static let starterFoods: [FoodItem] = [
        FoodItem(id: "kibble", name: "Kibble", emoji: "🥣", treatCost: 0, satiety: 25),
        FoodItem(id: "cookie", name: "Cookie", emoji: "🍪", treatCost: 1, satiety: 40),
        FoodItem(id: "sushi", name: "Sushi", emoji: "🍣", treatCost: 2, satiety: 65),
        FoodItem(id: "feast", name: "Feast", emoji: "🍱", treatCost: 3, satiety: 90),
    ]
}

/// 寵物的持久化狀態(本機 JSON)。
public struct PetStateData: Codable, Sendable {
    public var hunger: Double
    public var xp: Double
    public var lastDecayAt: Date
    public var lastFedAt: Date?
    public var eatingUntil: Date?
    public var eatingFoodId: String?
    public var happyUntil: Date?
    public var celebrationUntil: Date?
    /// 當日狀態(dayKey 變更時歸零)
    public var dayKey: String
    public var treatsSpentToday: Int
    public var kibbleUsedToday: Int
    public var xpFromTokensToday: Double
    public var healthyBonusAwardedFor: String?
    public var totalFeeds: Int
    /// 今日是否進入過 warning/exhausted(健康日加成的依據)。
    public var warningSeenToday: Bool = false

    public init(now: Date = Date()) {
        hunger = 75
        xp = 0
        lastDecayAt = now
        dayKey = PetStateData.dayKey(for: now)
        treatsSpentToday = 0
        kibbleUsedToday = 0
        xpFromTokensToday = 0
        totalFeeds = 0
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public var level: Int { Int((xp / 100).squareRoot()) + 1 }
}
