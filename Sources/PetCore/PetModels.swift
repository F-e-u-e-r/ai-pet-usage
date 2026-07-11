import Foundation

public enum PetSpecies: String, Codable, CaseIterable, Sendable {
    case dog
    case cat

    public var displayName: String { self == .dog ? "Golden Retriever" : "Black Cat" }

    /// 選單列/面板開頭的物種標記(spec:menu bar 以所選寵物開頭,取代 🐾/警示 emoji)。
    public var emoji: String { self == .dog ? "🐶" : "🐱" }

    // MARK: - EngineV2 pack id 相容層(M2 §3-A;enum 為 legacy 儲存形態)

    /// EngineV2 SpeciesPack id(enum → pack id:dog→"dog"、cat→"cat")。
    public var packId: String { rawValue }

    /// pack id → legacy 物種;未知 id 回 nil(呼叫端依 flag 矩陣落到 "dog")。
    public init?(packId: String) {
        self.init(rawValue: packId)
    }

    /// settings facade 的共用語意(FIX-4):儲存的覆寫 id 優先,否則 enum 對映。
    /// `AppSettings.speciesPackId` 委派此處 —— 讓 bird 等未來 pack id 可經
    /// `speciesPackIdOverride` 到達,而儲存的 species enum 保持不動。
    public static func effectivePackId(override: String?, stored: PetSpecies) -> String {
        override ?? stored.packId
    }

    /// pack id 解析為 legacy 物種:未知 id → .dog(flag 矩陣:未知→"dog";
    /// `AppSettings.resolvedSpecies` 委派此處,override 存在時此路徑真正可達)。
    public static func resolved(fromPackId id: String) -> PetSpecies {
        PetSpecies(packId: id) ?? .dog
    }
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

    /// 物種化菜單(UIUX spec §10):同一組 id/成本/飽足度,只換名稱與 emoji——
    /// id 穩定確保 eatingFoodId 等持久化狀態跨物種切換仍有效。
    public static let dogFoods: [FoodItem] = [
        FoodItem(id: "kibble", name: "Kibble", emoji: "🥣", treatCost: 0, satiety: 25),
        FoodItem(id: "cookie", name: "Training Biscuit", emoji: "🦴", treatCost: 1, satiety: 40),
        FoodItem(id: "sushi", name: "Chicken Bite", emoji: "🍗", treatCost: 2, satiety: 65),
        FoodItem(id: "feast", name: "Dinner Bowl", emoji: "🍲", treatCost: 3, satiety: 90),
    ]

    public static let catFoods: [FoodItem] = [
        FoodItem(id: "kibble", name: "Kibble", emoji: "🥣", treatCost: 0, satiety: 25),
        FoodItem(id: "cookie", name: "Tuna Bite", emoji: "🐟", treatCost: 1, satiety: 40),
        FoodItem(id: "sushi", name: "Chicken Shred", emoji: "🍗", treatCost: 2, satiety: 65),
        FoodItem(id: "feast", name: "Gourmet Bowl", emoji: "🍲", treatCost: 3, satiety: 90),
    ]

    public static func foods(for species: PetSpecies) -> [FoodItem] {
        species == .dog ? dogFoods : catFoods
    }
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
