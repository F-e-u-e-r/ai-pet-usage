import Foundation
import CoreGraphics

// MARK: - 型別(§8 凍結契約)

public struct BehaviorEdge: Sendable {
    public var next: PetActionID
    public var weight: Double
    /// 區域條件邊:nil = 任何區域皆可。
    public var region: RegionKind?

    public init(next: PetActionID, weight: Double, region: RegionKind? = nil) {
        self.next = next
        self.weight = weight
        self.region = region
    }
}

public struct BehaviorTable: Sendable {
    /// 加權轉移列:目前動作 → 候選邊。
    public var rows: [PetActionID: [BehaviorEdge]]
    /// 各動作的 mood tier;與當前 mood tier 的距離每層 ×0.25 衰減。
    public var moodTier: [PetActionID: Int]

    public init(rows: [PetActionID: [BehaviorEdge]], moodTier: [PetActionID: Int]) {
        self.rows = rows
        self.moodTier = moodTier
    }
}

/// 全域遮罩。缺動畫(missingFrames)與使用者停用(userDisabled)屬於逐動作資訊,
/// 依契約「集合另傳」— 由呼叫端自 `available` 集合剔除;此 OptionSet 只載全域旗標。
public struct BehaviorMasks: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// 系統減少動態:graph flavor 全遮,回靜態姿勢集(idle)。
    public static let reduceMotion = BehaviorMasks(rawValue: 1 << 0)
    /// quiet mode:graph flavor 全遮(dock 迷你路徑屬 E3,E0 僅遮罩語意)。
    public static let quiet = BehaviorMasks(rawValue: 1 << 1)
}

public protocol BehaviorGraphing: AnyObject {
    func next(after: PetActionID, moodTier: Int, masks: BehaviorMasks,
              available: Set<PetActionID>, region: RegionKind,
              rng: inout any RandomNumberGenerator) -> PetActionID
}

// MARK: - 全域優先表骨架(§3-B;雙車道仲裁的決定性基準)

/// 優先序:exhausted > alert > 使用者互動(drag/feed)> transient(celebrating/working3)
/// > 階段式入睡/dock 收合 > graph flavor。rawValue 越大越優先。
public enum GlobalPriority: Int, Comparable, CaseIterable, Sendable {
    case graphFlavor = 0
    case sleepOrDock = 1
    case transient = 2
    case userInteraction = 3
    case alert = 4
    case exhausted = 5

    public static func < (lhs: GlobalPriority, rhs: GlobalPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 決定性仲裁:同時活躍的車道取最高優先者(空集合 = 無仲裁需求)。
    public static func winner(_ active: Set<GlobalPriority>) -> GlobalPriority? {
        active.max()
    }
}

/// 互動車道佇列(E1 取法 A 案:互動請求有專用車道,不與 graph flavor 混流)。
///
/// 外部互動(點擊/餵食等)`enqueue` 排隊;EngineLoop 每 tick 起點 `dequeue` 一件,
/// 以 `GlobalPriority.userInteraction` 語意**即刻搶佔** graph flavor(換動作不等播畢)。
/// 拖曳期間不消化 —— 拖曳是同車道內更即時的互動,佇列請求等放手後的 tick 接手。
/// FIFO、每 tick 至多一件;空佇列 = 行為與無此車道時位元一致(決定性不受影響)。
public struct InteractionLane: Sendable {
    private var queue: [PetActionID] = []

    public init() {}

    public var isEmpty: Bool { queue.isEmpty }

    /// 排入一筆互動請求(FIFO)。
    public mutating func enqueue(_ action: PetActionID) {
        queue.append(action)
    }

    /// 取出下一筆待處理互動;無則 nil。
    public mutating func dequeue() -> PetActionID? {
        queue.isEmpty ? nil : queue.removeFirst()
    }
}

// MARK: - BehaviorGraph

/// 加權轉移圖:區域條件邊 + mood tier 距離衰減(×0.25/層)+ 遮罩;
/// 遮罩後零權重列一律 fallback → idle。抽選以呼叫端傳入的 RNG 決定(同 seed 位元一致)。
public final class BehaviorGraph: BehaviorGraphing {
    public let table: BehaviorTable

    public init(table: BehaviorTable) {
        self.table = table
    }

    public func next(after: PetActionID, moodTier: Int, masks: BehaviorMasks,
                     available: Set<PetActionID>, region: RegionKind,
                     rng: inout any RandomNumberGenerator) -> PetActionID {
        // reduce-motion / quiet:graph flavor 整層遮罩 → 靜態姿勢集(idle)。
        if masks.contains(.reduceMotion) || masks.contains(.quiet) { return .idle }

        // 過濾(區域條件、缺動畫/停用集合)+ mood tier 距離衰減。
        var candidates: [(next: PetActionID, weight: Double)] = []
        for edge in table.rows[after] ?? [] {
            if let required = edge.region, required != region { continue }
            guard available.contains(edge.next) else { continue }
            let tier = table.moodTier[edge.next] ?? 0
            let weight = edge.weight * pow(0.25, Double(abs(tier - moodTier)))
            if weight > 0 { candidates.append((edge.next, weight)) }
        }

        let total = candidates.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return .idle }   // 遮罩後零權重列 fallback → idle。

        // 決定性加權抽選:上位 53 bits → [0,1),不經 Double.random(跨版本位元穩定)。
        var r = Double(rng.next() >> 11) * 0x1p-53 * total
        for candidate in candidates {
            r -= candidate.weight
            if r < 0 { return candidate.next }
        }
        return candidates[candidates.count - 1].next
    }
}
