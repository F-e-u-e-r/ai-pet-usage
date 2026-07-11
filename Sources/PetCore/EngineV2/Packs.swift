import Foundation
import CoreGraphics

// MARK: - PetActionID(§8 凍結契約)

/// 字串型別安全的動作識別;`PixelAnimState` 為 legacy 相容層(flag 關原路徑不動)。
public struct PetActionID: RawRepresentable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

extension PetActionID {
    // 常用槽位(僅便利常數,不限制 pack 自訂動作)。
    public static let idle = PetActionID(rawValue: "idle")
    public static let drag = PetActionID(rawValue: "drag")
    public static let float = PetActionID(rawValue: "float")
    public static let flyFlap = PetActionID(rawValue: "flyFlap")
    public static let glide = PetActionID(rawValue: "glide")
    public static let working1 = PetActionID(rawValue: "working1")
}

// MARK: - SpeciesPack(§8 凍結契約)

/// 物種資料包契約。`frames` 沿既有字串網格慣例:每元素一幀,
/// 幀 = gridHeight 列(\n 分隔)× gridWidth 字元('.' 透明)。
public struct SpeciesPack: Sendable {
    public var id: String
    public var displayName: String
    public var gridWidth: Int
    public var gridHeight: Int
    public var frames: [PetActionID: [String]]
    public var requiredSlots: Set<PetActionID>            // {idle, drag 或 float}
    public var optionalSlots: Set<PetActionID>
    public var fallback: [PetActionID: PetActionID]
    public var behavior: BehaviorTable
    public var locomotion: LocomotionProfile
    public var anchorOffsets: [PetActionID: CGPoint]      // 底部中心錨之偏移
    public var mirrorSafe: Set<PetActionID>

    public init(id: String, displayName: String, gridWidth: Int, gridHeight: Int,
                frames: [PetActionID: [String]], requiredSlots: Set<PetActionID>,
                optionalSlots: Set<PetActionID>, fallback: [PetActionID: PetActionID],
                behavior: BehaviorTable, locomotion: LocomotionProfile,
                anchorOffsets: [PetActionID: CGPoint], mirrorSafe: Set<PetActionID>) {
        self.id = id
        self.displayName = displayName
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.frames = frames
        self.requiredSlots = requiredSlots
        self.optionalSlots = optionalSlots
        self.fallback = fallback
        self.behavior = behavior
        self.locomotion = locomotion
        self.anchorOffsets = anchorOffsets
        self.mirrorSafe = mirrorSafe
    }
}

// MARK: - PackRegistry

/// 物種包註冊表:register / pack(id:) / resolve(action:in:) 沿 fallback 鏈解析缺幀。
public final class PackRegistry {
    private var packs: [String: SpeciesPack] = [:]

    public init() {}

    public func register(_ pack: SpeciesPack) {
        packs[pack.id] = pack
    }

    public func pack(id: String) -> SpeciesPack? {
        packs[id]
    }

    /// 缺幀(無條目或空陣列)沿 fallback 鏈走訪;斷鏈或環一律終止於 idle。
    public func resolve(_ action: PetActionID, in pack: SpeciesPack) -> PetActionID {
        var current = action
        var visited: Set<PetActionID> = []
        while (pack.frames[current]?.isEmpty ?? true) {
            guard visited.insert(current).inserted, let next = pack.fallback[current] else {
                return .idle
            }
            current = next
        }
        return current
    }
}
