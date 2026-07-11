import Foundation
import CoreGraphics

/// 內建物種包工廠(E0:鳥 Flyer 佔位包 + 假 pack)。
/// 佔位美術為原創手排 24×24 字串網格('.' 透明;b 身體 / w 翅 / e 眼 / k 喙 / f 足 / t 鍵盤),
/// 沿既有字串網格慣例:每元素一幀,列以換行分隔。美術品質不在 E0 評分,E2a 換真 sheets。
public enum SpeciesPacks {

    /// 鳥(Flyer)最小佔位包:idle/flyFlap/glide/drag/working1 各 2–4 幀。
    public static func birdPlaceholder() -> SpeciesPack {
        let behavior = BehaviorTable(
            rows: [
                .idle: [
                    BehaviorEdge(next: .idle, weight: 3),
                    BehaviorEdge(next: .flyFlap, weight: 2, region: .air),
                    BehaviorEdge(next: .glide, weight: 1, region: .air),
                    BehaviorEdge(next: .working1, weight: 1.5),
                    // FIX-5:地面起飛入口 —— 著地後 idle→flyFlap 必須在 ground 區可達,
                    // 否則 air 條件邊全遭遮罩,鳥著地一次即永久軟鎖(G1 demo 硬需求)。
                    BehaviorEdge(next: .flyFlap, weight: 2, region: .ground),
                ],
                .flyFlap: [
                    BehaviorEdge(next: .idle, weight: 2),
                    BehaviorEdge(next: .glide, weight: 2, region: .air),
                    BehaviorEdge(next: .flyFlap, weight: 1),
                ],
                .glide: [
                    BehaviorEdge(next: .flyFlap, weight: 2, region: .air),
                    BehaviorEdge(next: .idle, weight: 1),
                ],
                .working1: [
                    BehaviorEdge(next: .idle, weight: 2),
                    BehaviorEdge(next: .working1, weight: 1),
                ],
            ],
            // working1 為 burn 檔 1 的 mood 態(tier 1);其餘皆基準 tier 0。
            moodTier: [.idle: 0, .flyFlap: 0, .glide: 0, .working1: 1, .drag: 0])

        return SpeciesPack(
            id: "bird",
            displayName: "Bird",
            gridWidth: 24,
            gridHeight: 24,
            frames: birdFrames,
            requiredSlots: [.idle, .drag],
            optionalSlots: [.glide, .working1],
            fallback: [.glide: .flyFlap, .working1: .idle, .float: .idle],
            behavior: behavior,
            locomotion: .flyer,
            anchorOffsets: [.idle: .zero, .flyFlap: CGPoint(x: 0, y: -1),
                            .glide: CGPoint(x: 0, y: -1), .drag: CGPoint(x: 0, y: 1),
                            .working1: .zero],
            mirrorSafe: [.idle, .flyFlap, .glide])
    }

    /// 假 pack(測 fallback):requiredSlots 宣告 float 卻缺幀、fallback 含環與斷鏈、
    /// 非方形 8×6 網格(協議 grid-agnostic 冒煙)。
    public static func brokenSample() -> SpeciesPack {
        let dance = PetActionID(rawValue: "dance")
        let spin = PetActionID(rawValue: "spin")
        let ghost = PetActionID(rawValue: "ghost")
        return SpeciesPack(
            id: "broken-sample",
            displayName: "Broken Sample",
            gridWidth: 8,
            gridHeight: 6,
            frames: [
                .idle: ["..pppp..\n.pppppp.\n.pp..pp.\n.pppppp.\n..pppp..\n........"],
                spin: [],   // 空陣列 = 缺幀(mid-chain 測試用)。
            ],
            requiredSlots: [.idle, .float],
            optionalSlots: [dance, spin, ghost],
            fallback: [.float: .idle,          // 缺槽位 → idle。
                       dance: spin, spin: dance,   // 環:必須終止於 idle。
                       ghost: PetActionID(rawValue: "nowhere")],   // 斷鏈 → idle。
            behavior: BehaviorTable(rows: [.idle: [BehaviorEdge(next: .idle, weight: 1)]],
                                    moodTier: [:]),
            locomotion: .swimmer,
            anchorOffsets: [:],
            mirrorSafe: [])
    }

    // MARK: - 鳥佔位幀(產生自原創手排網格;每幀 24 列 × 24 字元)

    private static let birdFrames: [PetActionID: [String]] = [
        .idle: [
            "........................\n........................\n........................\n........................\n........................\n........................\n.........bbbbbb.........\n.........bbbbek.........\n.........bbbbbb.........\n.........bbbbbb.........\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.....wwbbbbbbbbbbww.....\n.....wwbbbbbbbbbbww.....\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n..........bbbb..........\n..........bbbb..........\n..........f..f..........\n........................\n........................\n........................\n........................",
            "........................\n........................\n........................\n........................\n........................\n........................\n.........bbbbbb.........\n.........bbbbek.........\n.........bbbbbb.........\n.........bbbbbb.........\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.....wwbbbbbbbbbbww.....\n.....wwbbbbbbbbbbww.....\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n..........bbbb..........\n..........bbbb..........\n..........f..f..........\n........................\n........................\n........................\n........................",
        ],
        .flyFlap: [
            "........................\n........................\n........................\n........................\n........................\n........................\n.........bbbbbb.........\n.........bbbbek.........\n.....ww..bbbbbb..ww.....\n......w..bbbbbb..w......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n..........bbbb..........\n..........bbbb..........\n..........f..f..........\n........................\n........................\n........................\n........................",
            "........................\n........................\n........................\n........................\n........................\n........................\n.........bbbbbb.........\n.........bbbbek.........\n.........bbbbbb.........\n.........bbbbbb.........\n....wwwbbbbbbbbbbwww....\n.....wwbbbbbbbbbbww.....\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n..........bbbb..........\n..........bbbb..........\n..........f..f..........\n........................\n........................\n........................\n........................",
            "........................\n........................\n........................\n........................\n........................\n........................\n.........bbbbbb.........\n.........bbbbek.........\n.........bbbbbb.........\n.........bbbbbb.........\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.....wwbbbbbbbbbbww.....\n.....wwbbbbbbbbbbww.....\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n..........bbbb..........\n..........bbbb..........\n..........f..f..........\n........................\n........................\n........................\n........................",
            "........................\n........................\n........................\n........................\n........................\n........................\n.........bbbbbb.........\n.........bbbbek.........\n.........bbbbbb.........\n.........bbbbbb.........\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.....wwbbbbbbbbbbww.....\n....wwwbbbbbbbbbbwww....\n..........bbbb..........\n..........bbbb..........\n..........f..f..........\n........................\n........................\n........................\n........................",
        ],
        .glide: [
            "........................\n........................\n........................\n........................\n........................\n........................\n.........bbbbbb.........\n.........bbbbek.........\n.........bbbbbb.........\n.........bbbbbb.........\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n..wwwwwbbbbbbbbbbwwwww..\n...wwwwbbbbbbbbbbwwww...\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n..........bbbb..........\n..........bbbb..........\n..........f..f..........\n........................\n........................\n........................\n........................",
            "........................\n........................\n........................\n........................\n........................\n........................\n.........bbbbbb.........\n.........bbbbek.........\n.........bbbbbb.........\n.........bbbbbb.........\n.......bbbbbbbbbb.......\n...wwwwbbbbbbbbbbwwww...\n..wwwwwbbbbbbbbbbwwwww..\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n..........bbbb..........\n..........bbbb..........\n..........f..f..........\n........................\n........................\n........................\n........................",
        ],
        .drag: [
            "........................\n........................\n........................\n........................\n........................\n........................\n.........bbbbbb.........\n.........bbbbek.........\n.....ww..bbbbbb..ww.....\n......w..bbbbbb..w......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n..........bbbb..........\n..........bbbb..........\n.........f....f.........\n........................\n........................\n........................\n........................",
            "........................\n........................\n........................\n........................\n........................\n........................\n.........bbbbbb.........\n.........bbbbek.........\n.........bbbbbb.........\n.........bbbbbb.........\n....wwwbbbbbbbbbbwww....\n.....wwbbbbbbbbbbww.....\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n..........bbbb..........\n..........bbbb..........\n.........f....f.........\n........................\n........................\n........................\n........................",
        ],
        .working1: [
            "........................\n........................\n........................\n........................\n........................\n........................\n.........bbbbbb.........\n.........bbbbbb.........\n.........bbbbek.........\n.........bbbbbb.........\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.....wwbbbbbbbbbbww.....\n.....wwbbbbbbbbbbww.....\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n..........bbbb..........\n..........bbbb..........\n..........f..f..........\n........tttttttt........\n........................\n........................\n........................",
            "........................\n........................\n........................\n........................\n........................\n........................\n.........bbbbbb.........\n.........bbbbek.........\n.........bbbbbb.........\n.........bbbbbb.........\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.....wwbbbbbbbbbbww.....\n.....wwbbbbbbbbbbww.....\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n.......bbbbbbbbbb.......\n..........bbbb..........\n..........bbbb..........\n..........f..f..........\n........tttttttt........\n........................\n........................\n........................",
        ]
    ]
}
