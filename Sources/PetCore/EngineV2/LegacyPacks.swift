import Foundation
import CoreGraphics

// MARK: - 狗/貓 legacy 遷移包(E1 計畫 §3-C)
//
// 把 PixelArt.swift 的既有字串網格**原封包裹**成 SpeciesPack(零重繪):
// 幀資料直接取自 `PixelPets.sprite(for:)`,只做「列陣列 → \n 串接」的機械轉換;
// 行為等價 golden(EngineV2LegacyPackTests)逐狀態逐幀斷言 pack 解析結果與
// legacy sprite 網格字串完全相等 —— 遷移在視覺上可證明地什麼都沒改。
//
// legacy `PixelAnimState` → `PetActionID`:rawValue 直通(相容層;flag 關原路徑不動)。

extension PetActionID {
    // 狗/貓 legacy 槽位(bird 佔位包之外的既有動作)。
    public static let walk = PetActionID(rawValue: "walk")
    public static let sit = PetActionID(rawValue: "sit")
    public static let sleep = PetActionID(rawValue: "sleep")
    public static let eat = PetActionID(rawValue: "eat")
    public static let jump = PetActionID(rawValue: "jump")
    public static let happy = PetActionID(rawValue: "happy")
    public static let alert = PetActionID(rawValue: "alert")
    public static let focusStart = PetActionID(rawValue: "focusStart")
    public static let focusedActive = PetActionID(rawValue: "focusedActive")
    public static let focusEnd = PetActionID(rawValue: "focusEnd")
}

extension SpeciesPacks {

    /// legacy `PixelAnimState` → `PetActionID`(rawValue 直通;等價 golden 依此對照)。
    public static func actionID(for state: PixelAnimState) -> PetActionID {
        PetActionID(rawValue: state.rawValue)
    }

    /// 狗(Walker)遷移包:包裹金毛的既有幀。
    public static func dogPack() -> SpeciesPack {
        legacyWalkerPack(species: .dog)
    }

    /// 貓(Walker)遷移包:包裹黑貓的既有幀(含 focus 三態)。
    public static func catPack() -> SpeciesPack {
        legacyWalkerPack(species: .cat)
    }

    // MARK: - 共用建構

    /// 以 legacy sprite 為單一事實來源建 pack:幀、網格尺寸、缺態 fallback 全部機械推導。
    private static func legacyWalkerPack(species: PetSpecies) -> SpeciesPack {
        let sprite = PixelPets.sprite(for: species)
        let frames = wrappedFrames(of: sprite)

        // 缺態 fallback:凡 legacy 宣告過(PixelAnimState.allCases)但該物種沒畫的狀態
        // → idle,一如 `PixelSprite.frames(for:)` 的 idle fallback(狗的 focus 三態走此路)。
        // drag/float 為 pack 契約槽位,legacy 無對應美術 → 同樣退回 idle。
        var fallback: [PetActionID: PetActionID] = [.drag: .idle, .float: .idle]
        for state in PixelAnimState.allCases where sprite.animations[state] == nil {
            fallback[actionID(for: state)] = .idle
        }

        // graph flavor 轉移表(原創手調;非 legacy 行為移植 —— legacy 的狀態切換由
        // mood 決定性驅動,那屬 overlay/優先車道,E3 才接線。此表只涵蓋漫遊層:
        // idle ↔ walk ↔ sit 的平靜循環,權重偏向 idle,與 legacy wander 的節奏相稱)。
        let behavior = BehaviorTable(
            rows: [
                .idle: [
                    BehaviorEdge(next: .idle, weight: 4),
                    BehaviorEdge(next: .walk, weight: 2, region: .ground),
                    BehaviorEdge(next: .sit, weight: 1),
                ],
                .walk: [
                    BehaviorEdge(next: .walk, weight: 2, region: .ground),
                    BehaviorEdge(next: .idle, weight: 2),
                ],
                .sit: [
                    BehaviorEdge(next: .idle, weight: 2),
                    BehaviorEdge(next: .sit, weight: 1),
                ],
            ],
            moodTier: [:])

        // mirror 語意:legacy 渲染(PetView)向左漫遊時整張 sprite 翻轉、不分狀態
        // (`flipped: wanderDirection < 0`),故所有有幀動作皆視為 mirror-safe,
        // 與既有視覺行為一致。
        return SpeciesPack(
            id: species.packId,
            displayName: species.displayName,
            gridWidth: sprite.width,
            gridHeight: sprite.height,
            frames: frames,
            requiredSlots: [.idle, .drag],
            optionalSlots: Set(frames.keys).subtracting([.idle]),
            fallback: fallback,
            behavior: behavior,
            locomotion: .walker,
            anchorOffsets: [:],
            mirrorSafe: Set(frames.keys))
    }

    /// legacy 幀(列字串陣列)→ pack 幀(\n 串接網格字串)。純機械轉換,不動任何字元。
    private static func wrappedFrames(of sprite: PixelSprite) -> [PetActionID: [String]] {
        var frames: [PetActionID: [String]] = [:]
        for (state, list) in sprite.animations {
            frames[actionID(for: state)] = list.map { $0.joined(separator: "\n") }
        }
        return frames
    }
}
