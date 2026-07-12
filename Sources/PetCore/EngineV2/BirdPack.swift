import Foundation
import CoreGraphics

/// 內建物種包工廠(E2a:藍鳥真美術;E0 佔位方塊已退役)。
/// 幀為原創手排 24×24 字串網格('.' 透明,其餘字元查 `palette` 取色),
/// 沿凍結美術規則(M2 §4):正面大頭 ≥55% 高、≤9 色、1px 外框、灰階剪影 =
/// 喙(下緣加深框)+ 翅(暗藍)+ 尾(腳間暗藍楔)。配色:藍身、橘喙橘腳
///(0xE8823A 與 app 既有暖色一致)、奶白腹(灰階對比)、腮紅(與貓同語彙)。
/// 行為表/錨點/槽位/fallback 與 E0 佔位包**逐字相同**(EngineV2Tests golden 釘住:
/// 換皮不換行為)。
public enum SpeciesPacks {

    /// 鳥(Flyer)包:idle 2 / flyFlap 4 / glide 2 / drag 2 / working1 2,真美術。
    public static func birdPack() -> SpeciesPack {
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
            mirrorSafe: [.idle, .flyFlap, .glide],
            palette: birdPalette)
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

    // MARK: - 鳥 palette(9 色;≤9 為 M2 §4 硬上限,golden 測試釘住)

    static let birdPalette: [Character: UInt32] = [
        "O": 0x24354F, // 外框深藍(深色桌面可見)
        "b": 0x4C8DE8, // 主體藍(使用者指定)
        "d": 0x3568B8, // 暗藍(翅/尾/陰影/鍵盤)
        "l": 0x8FBCF5, // 亮藍(頭頂高光/翅上緣)
        "c": 0xEAF1FB, // 腹部奶白(灰階對比)
        "k": 0xE8823A, // 喙+腳 橘(使用者指定;同 app 暖色)
        "e": 0x1C2026, // 眼
        "w": 0xFFFFFF, // 眼光/驚訝白眼/鍵帽點
        "p": 0xE08BA8, // 腮紅(與貓同色語彙)
    ]

    // MARK: - 鳥幀(原創手排網格;每幀 24 列 × 24 字元,'\n' 分隔)

    private static let birdFrames: [PetActionID: [String]] = [
        .idle: [
            "........................\n........................\n.........OOOOOO.........\n.......OOllllllOO.......\n......OllbbbbbbllO......\n.....OlbbbbbbbbbblO.....\n.....ObbbbbbbbbbbbO.....\n....ObbeebbbbbbeebbO....\n....ObeeeebbbbeeeebO....\n....ObewebbbbbbewebO....\n....ObeeebkkkkbeeebO....\n....ObpbbOkkkkObbpbO....\n.....ObbbbOOOObbbbO.....\n.....ObbbcccccbbbbO.....\n..OOObbccccccccbbbOOO...\n.OddObbccccccccbbbOddO..\n.OddbObccccccccbObdddO..\n..OObbbccccccccbbbOO....\n....ObbbccccccbbbO......\n.....OObbbbbbbbOO.......\n.......OkkOddOkkO.......\n.......Okk.dd.kkO.......\n.......kkk....kkk.......\n........................",
            "........................\n........................\n........................\n.........OOOOOO.........\n.......OOllllllOO.......\n.....OOlbbbbbbbblOO.....\n.....ObbbbbbbbbbbbO.....\n....ObbeebbbbbbeebbO....\n....ObeeeebbbbeeeebO....\n....ObewebbbbbbewebO....\n....ObeeebkkkkbeeebO....\n....ObpbbOkkkkObbpbO....\n.....ObbbbOOOObbbbO.....\n.....ObbbcccccbbbbO.....\n..OOObbccccccccbbbOOO...\n.OddObbccccccccbbbOddO..\n.OddbObccccccccbObdddO..\n..OObbbccccccccbbbOO....\n....ObbbccccccbbbO......\n.....OObbbbbbbbOO.......\n.......OkkOddOkkO.......\n.......Okk.dd.kkO.......\n.......kkk....kkk.......\n........................",
        ],
        .flyFlap: [
            "........................\n........................\n.........OOOOOO.........\n.......OOllllllOO.......\n..Ol..OllbbbbbbllO..lO..\n.OllO.OlbbbbbbbbblOOllO.\n.OldOOObbbbbbbbbbbOOdlO.\n.OddObbeebbbbbbeebbOddO.\n..OOObeeeebbbbeeeebOOO..\n....ObewebbbbbbewebO....\n....ObeeebkkkkbeeebO....\n....ObpbbOkkkkObbpbO....\n.....ObbbbOOOObbbbO.....\n.....ObbbcccccbbbbO.....\n....ObbccccccccbbbO.....\n....ObbccccccccbbbO.....\n.....ObccccccccbO.......\n.....ObccccccccbO.......\n....ObbbccccccbbbO......\n.....OObbbbbbbbOO.......\n.......OObddbOO.........\n.........OddO...........\n..........OO............\n........................",
            "........................\n........................\n.........OOOOOO.........\n.......OOllllllOO.......\n......OllbbbbbbllO......\n.....OlbbbbbbbbbblO.....\n.....ObbbbbbbbbbbbO.....\n....ObbeebbbbbbeebbO....\n....ObeeeebbbbeeeebO....\nOOOOObewebbbbbbewebOOOOO\nllllObeeebkkkkbeeebOllll\nddddObpbbOkkkkObbpbOdddd\n.OOOOObbbbOOOObbbbOOOOO.\n.....ObbbcccccbbbbO.....\n..OOObbccccccccbbbOOO...\n.OddObbccccccccbbbOddO..\n.OddbObccccccccbObdddO..\n..OObbbccccccccbbbOO....\n....ObbbccccccbbbO......\n.....OObbbbbbbbOO.......\n.......OObddbOO.........\n.........OddO...........\n..........OO............\n........................",
            "........................\n........................\n.........OOOOOO.........\n.......OOllllllOO.......\n......OllbbbbbbllO......\n.....OlbbbbbbbbbblO.....\n.....ObbbbbbbbbbbbO.....\n....ObbeebbbbbbeebbO....\n....ObeeeebbbbeeeebO....\n....ObewebbbbbbewebO....\n....ObeeebkkkkbeeebO....\n....ObpbbOkkkkObbpbO....\nOOOOOObbbbOOOObbbbOOOOOO\nlllllObbbcccccbbbbOlllll\nddOOObbccccccccbbbOOO.dd\nOOddObbccccccccbbbOddO.O\n.OddbObccccccccbObdddO..\n..OObbbccccccccbbbOO....\n....ObbbccccccbbbO......\n.....OObbbbbbbbOO.......\n.......OObddbOO.........\n.........OddO...........\n..........OO............\n........................",
            "........................\n........................\n.........OOOOOO.........\n.......OOllllllOO.......\n......OllbbbbbbllO......\n.....OlbbbbbbbbbblO.....\n.....ObbbbbbbbbbbbO.....\n....ObbeebbbbbbeebbO....\n....ObeeeebbbbeeeebO....\n....ObewebbbbbbewebO....\n....ObeeebkkkkbeeebO....\n....ObpbbOkkkkObbpbO....\n.....ObbbbOOOObbbbO.....\n.....ObbbcccccbbbbO.....\n..OOObbccccccccbbbOOO...\n...OddObccccccccbOddO...\n....OddObccccccbOddO....\n.....OddbbccccbbddO.....\n......OObbccccbOO.......\n.....OObbbbbbbbOO.......\n.......OObddbOO.........\n.........OddO...........\n..........OO............\n........................",
        ],
        .glide: [
            "........................\n........................\n.........OOOOOO.........\n.......OOllllllOO.......\n......OllbbbbbbllO......\n.....OlbbbbbbbbbblO.....\n.....ObbbbbbbbbbbbO.....\n....ObbeebbbbbbeebbO....\n....ObeeeebbbbeeeebO....\n....ObewebbbbbbewebO....\n....ObeeebkkkkbeeebO....\nOOOOObpbbOkkkkObbpbOOOOO\nlllllObbbbOOOObbbbOlllll\ndddddObbbcccccbbbbOddddd\nOOOOObbccccccccbbbOOO.OO\n.OddObbccccccccbbbOddO..\n.OddbObccccccccbObdddO..\n..OObbbccccccccbbbOO....\n....ObbbccccccbbbO......\n.....OObbbbbbbbOO.......\n.......OObddbOO.........\n.........OddO...........\n..........OO............\n........................",
            "........................\n........................\n.........OOOOOO.........\n.......OOllllllOO.......\n......OllbbbbbbllO......\n.....OlbbbbbbbbbblO.....\n.....ObbbbbbbbbbbbO.....\n....ObbeebbbbbbeebbO....\n....ObeeeebbbbeeeebO....\n....ObewebbbbbbewebO....\nOOOOObeeebkkkkbeeebOOOOO\nllllObpbbOkkkkObbpbOllll\ndddddObbbbOOOObbbbOddddd\nOOOOOObbbcccccbbbbOOOOOO\n..OOObbccccccccbbbOOO...\n.OddObbccccccccbbbOddO..\n.OddbObccccccccbObdddO..\n..OObbbccccccccbbbOO....\n....ObbbccccccbbbO......\n.....OObbbbbbbbOO.......\n.......OObddbOO.........\n.........OddO...........\n..........OO............\n........................",
        ],
        .drag: [
            "........................\n........................\n.........OOOOOO.........\n.......OOllllllOO.......\n..Ol..OllbbbbbbllO..lO..\n.OllO.OlbbbbbbbbblOOllO.\n.OldOOObbbbbbbbbbbOOdlO.\n..OOObeeebbbbbbeeebOOO..\n....ObewwebbbbewwebO....\n....ObewwebbbbewwebO....\n....ObeeebkkkkbeeebO....\n....ObpbbOkkkkObbpbO....\n.....ObbbbOOOObbbbO.....\n.....ObbbcccccbbbbO.....\n..OOObbccccccccbbbOOO...\n.OddObbccccccccbbbOddO..\n.OddbObccccccccbObdddO..\n..OObbbccccccccbbbOO....\n....ObbbccccccbbbO......\n.....OObbbbbbbbOO.......\n......OkkOddOOkkO.......\n.....Okk..dd...kkO......\n....kkk..........kkk....\n........................",
            "........................\n........................\n.........OOOOOO.........\n.......OOllllllOO.......\n..Ol..OllbbbbbbllO..lO..\n.OllO.OlbbbbbbbbblOOllO.\n.OldOOObbbbbbbbbbbOOdlO.\n..OOObeeebbbbbbeeebOOO..\n....ObewwebbbbewwebO....\n....ObewwebbbbewwebO....\n....ObeeebkkkkbeeebO....\n....ObpbbOkkkkObbpbO....\n.....ObbbbOOOObbbbO.....\n.....ObbbcccccbbbbO.....\n..OOObbccccccccbbbOOO...\n.OddObbccccccccbbbOddO..\n.OddbObccccccccbObdddO..\n..OObbbccccccccbbbOO....\n....ObbbccccccbbbO......\n.....OObbbbbbbbOO.......\n.......OkkOddOkkO.......\n......Okk.dd...kkO......\n.....kkk........kkk.....\n........................",
        ],
        .working1: [
            "........................\n........................\n.........OOOOOO.........\n.......OOllllllOO.......\n......OllbbbbbbllO......\n.....OlbbbbbbbbbblO.....\n.....ObbbbbbbbbbbbO.....\n....ObbeebbbbbbeebbO....\n....ObbbbbbbbbbbbbbO....\n....ObeeeebbbbeeeebO....\n....ObbwebkkkkbewbbO....\n....ObpbbOkkkkObbpbO....\n.....ObbbbOOOObbbbO.....\n.....ObbbcccccbbbbO.....\n..OOObbccccccccbbbOOO...\n.OddObbccccccccbbbOddO..\n.OddbObccccccccbObdddO..\n..OObbbccccccccbbbOO....\n....ObbbccccccbbbO......\n.....OObbbbbbbbOO.......\n.......OkkOddOkkO.......\n....OddddddddddddddO....\n....OdwdwdwdwdwdwdwO....\n........................",
            "........................\n........................\n.........OOOOOO.........\n.......OOllllllOO.......\n......OllbbbbbbllO......\n.....OlbbbbbbbbbblO.....\n.....ObbbbbbbbbbbbO.....\n....ObbeebbbbbbeebbO....\n....ObbbbbbbbbbbbbbO....\n....ObeeeebbbbeeeebO....\n....ObbwebkkkkbewbbO....\n....ObpbbOkkkkObbpbO....\n.....ObbbbOOOObbbbO.....\n.....ObbbcccccbbbbO.....\n..OOObbccccccccbbbOOO...\n.OddObbccccccccbbbOddO..\n.OddbObccccccccbObdddO..\n..OObbbccccccccbbbOO....\n....ObbbccccccbbbO......\n.....OObbbbbbbbOO.......\n.......OkkOddOkkO.......\n....OddddddddddddddO....\n....OdwdwwdwdwwdwdwO....\n........................",
        ],
    ]
}
