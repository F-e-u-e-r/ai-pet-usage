import Foundation

// 原創像素寵物圖(風格參考使用者提供的圖庫範例重新繪製,非複製任何素材)。
// 每幀為 height 列 × width 欄的字元網格:'.' 透明,其餘字元查 palette 取色。
// 美術以字串定義,方便直接在此檔調整造型。
//
// 風格語彙:
//   金毛 — 扁平無外框、大頭側面、垂耳+豎耳、黑方眼、粉色大舌、深項圈、方柱腿。
//   黑貓 — 胖圓一體、亮灰粗外框(深色桌面可見)、綠眼、粉腮紅、捲尾、正面坐姿。

public enum PixelAnimState: String, CaseIterable, Sendable {
    case idle, walk, sit, sleep, eat, jump
}

public struct PixelSprite: Sendable {
    public let width: Int
    public let height: Int
    /// 字元 → 0xRRGGBB
    public let palette: [Character: UInt32]
    public let animations: [PixelAnimState: [[String]]]

    public func frames(for state: PixelAnimState) -> [[String]] {
        animations[state] ?? animations[.idle] ?? []
    }
}

public enum PixelPets {

    public static func sprite(for species: PetSpecies) -> PixelSprite {
        species == .dog ? goldenRetriever : blackCat
    }

    /// mood(+ 是否正在漫遊行走)→ 動畫狀態。
    public static func animState(for mood: PetMood, walking: Bool) -> PixelAnimState {
        if walking, [.idle, .happy, .focused].contains(mood) { return .walk }
        switch mood {
        case .sleeping, .tired: return .sleep
        case .eating: return .eat
        case .celebration: return .jump
        case .focused: return .sit
        case .warning, .exhausted, .hungry, .confused: return .sit
        case .idle, .happy: return .idle
        }
    }

    /// 每個動畫的播放速率(frames/sec,乘上 mood 的 animationSpeed)。
    public static func fps(for state: PixelAnimState) -> Double {
        switch state {
        case .idle: return 1.4
        case .walk: return 5
        case .sit: return 1.1
        case .sleep: return 0.8
        case .eat: return 3.2
        case .jump: return 4.5
        }
    }

    // MARK: - Golden Retriever(20×18,右向側面,扁平無外框)

    static let goldenRetriever = PixelSprite(
        width: 20,
        height: 18,
        palette: [
            "A": 0xE8A33D, // 主體金黃
            "M": 0xC77F23, // 深金(垂耳/陰影)
            "C": 0xF6DFAE, // 奶油(胸口/腿間)
            "K": 0x26221E, // 眼/鼻/項圈
            "P": 0xE4577E, // 舌
            "T": 0x8A5A2B, // 零食
        ],
        animations: [
            .idle: [dogIdleA, dogIdleB],
            .walk: [dogWalkA, dogWalkB],
            .sit: [dogSitA, dogSitA],
            .sleep: [dogSleepA, dogSleepB],
            .eat: [dogEatA, dogEatB],
            .jump: [dogJumpA, dogEatB],
        ]
    )

    static let dogIdleA = [
        ".............AA.....",
        ".....MM.....AAAA....",
        "....MMMMAAAAAAAA....",
        "....MMMAAAAAAAAAA...",
        ".....MMAAAAAAKKAA...",
        ".......AAAAAAKKAAKK.",
        ".......AAAAAAAAAAKK.",
        "AA.....AAAAAAAAAA...",
        "AAA....AAAAAAAAPPP..",
        ".AA....KKKKKKKK.PP..",
        "...AAAAAAAAAAAA.PP..",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAAAAA.....",
        "..AAAAAAAAAAAAA.....",
        "...AACAACAACAA......",
        "...AA.AA.AA.AA......",
        "....................",
    ]

    static let dogIdleB = [
        "..............AA....",
        ".....MM.....AAAA....",
        "....MMMMAAAAAAAA....",
        "....MMMAAAAAAAAAA...",
        ".....MMAAAAAAKKAA...",
        ".......AAAAAAKKAAKK.",
        ".......AAAAAAAAAAKK.",
        ".......AAAAAAAAAA...",
        "AAA....AAAAAAAAPPP..",
        ".AA....KKKKKKKK.PP..",
        "...AAAAAAAAAAAA.PP..",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAAAAA.....",
        "..AAAAAAAAAAAAA.....",
        "...AACAACAACAA......",
        "...AA.AA.AA.AA......",
        "....................",
    ]

    static let dogWalkA = [
        ".............AA.....",
        ".....MM.....AAAA....",
        "....MMMMAAAAAAAA....",
        "....MMMAAAAAAAAAA...",
        ".....MMAAAAAAKKAA...",
        ".......AAAAAAKKAAKK.",
        ".......AAAAAAAAAAKK.",
        "AA.....AAAAAAAAAA...",
        "AAA....AAAAAAAAPPP..",
        ".AA....KKKKKKKK.PP..",
        "...AAAAAAAAAAAA.PP..",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAAAAA.....",
        "..AAAAAAAAAAAAA.....",
        "..AAC.AACAAC.AA.....",
        "..AA..AA.AA..AA.....",
        "....................",
    ]

    static let dogWalkB = [
        "..............AA....",
        ".....MM.....AAAA....",
        "....MMMMAAAAAAAA....",
        "....MMMAAAAAAAAAA...",
        ".....MMAAAAAAKKAA...",
        ".......AAAAAAKKAAKK.",
        ".......AAAAAAAAAAKK.",
        ".......AAAAAAAAAA...",
        "AAA....AAAAAAAAPPP..",
        ".AA....KKKKKKKK.PP..",
        "...AAAAAAAAAAAA.PP..",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAAAAA.....",
        "..AAAAAAAAAAAAA.....",
        "....AACAACAACAA.....",
        "....AA.AA.AA.AA.....",
        "....................",
    ]

    static let dogSitA = [
        ".............AA.....",
        ".....MM.....AAAA....",
        "....MMMMAAAAAAAA....",
        "....MMMAAAAAAAAAA...",
        ".....MMAAAAAAKKAA...",
        ".......AAAAAAKKAAKK.",
        ".......AAAAAAAAAAKK.",
        ".......AAAAAAAAAA...",
        ".......AAAAAAAAPPP..",
        ".......KKKKKKKK.PP..",
        ".....AAAAAAAAAA.PP..",
        "....AAAAAAAAAAA.....",
        "...AAAAAAAAAAAA.....",
        "...AAAAAAAAACCA.....",
        "...AAAAAA...AA......",
        "...AAAAAA...AA......",
        "....AAAA....AA......",
        "....................",
    ]

    static let dogSleepA = [
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        ".....AAAAAAAA.......",
        "...AAAAAAAAAAAA.....",
        "..AAAAAAAAAAAAAA....",
        "..AAAAAAAAAAKKAA....",
        "..AAAAAAAAAAAAAA....",
        "..AAMAAAAAAMAA......",
        "...AAAAAAAAAAAA.....",
        ".....AAAAAAAA.......",
        "....................",
    ]

    static let dogSleepB = [
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "......AAAAAA........",
        "....AAAAAAAAAA......",
        "...AAAAAAAAAAAA.....",
        "..AAAAAAAAAAAAAA....",
        "..AAAAAAAAAAKKAA....",
        "..AAAAAAAAAAAAAA....",
        "..AAMAAAAAAMAA......",
        "...AAAAAAAAAAAA.....",
        ".....AAAAAAAA.......",
        "....................",
    ]

    /// 躍起接零食(整體上移、後腿收起、零食在口前)
    static let dogEatA = [
        "....MMMMAAAAAAAA.TT.",
        "....MMMAAAAAAAAAA...",
        ".....MMAAAAAAKKAA...",
        ".......AAAAAAKKAAKK.",
        ".......AAAAAAAAAAKK.",
        "AA.....AAAAAAAAAA...",
        "AAA....AAAAAAAAPPP..",
        ".AA....KKKKKKKK.PP..",
        "...AAAAAAAAAAAA.PP..",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAAAAA.....",
        "..AAAAAAAAAAAAA.....",
        "....AAAA..AAAA......",
        "....................",
        "....................",
        "....................",
        "....................",
    ]

    /// 落地大口咀嚼(舌頭伸長、零食吃掉)
    static let dogEatB = [
        ".............AA.....",
        ".....MM.....AAAA....",
        "....MMMMAAAAAAAA....",
        "....MMMAAAAAAAAAA...",
        ".....MMAAAAAAKKAA...",
        ".......AAAAAAKKAAKK.",
        ".......AAAAAAAAAAKK.",
        "AA.....AAAAAAAAAA...",
        "AAA....AAAAAAAAPPPP.",
        ".AA....KKKKKKKK.PPP.",
        "...AAAAAAAAAAAA.PP..",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAAAAA.....",
        "..AAAAAAAAAAAAA.....",
        "...AACAACAACAA......",
        "...AA.AA.AA.AA......",
        "....................",
    ]

    /// 慶祝跳躍(騰空、無零食)
    static let dogJumpA = [
        "....MMMMAAAAAAAA....",
        "....MMMAAAAAAAAAA...",
        ".....MMAAAAAAKKAA...",
        ".......AAAAAAKKAAKK.",
        ".......AAAAAAAAAAKK.",
        "AA.....AAAAAAAAAA...",
        "AAA....AAAAAAAAPPP..",
        ".AA....KKKKKKKK.PP..",
        "...AAAAAAAAAAAA.PP..",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAAAAA.....",
        "..AAAAAAAAAAAAA.....",
        "....AAAA..AAAA......",
        "....................",
        "....................",
        "....................",
        "....................",
    ]

    // MARK: - Black Cat(20×18,正面坐姿胖圓、亮灰外框、綠眼、粉腮紅)

    static let blackCat = PixelSprite(
        width: 20,
        height: 18,
        palette: [
            "O": 0x707887, // 外框(深色桌面可見)
            "B": 0x262A31, // 身體
            "S": 0x3D434E, // 條紋/闔眼線
            "E": 0x7FE08A, // 綠眼
            "P": 0xE08BA8, // 腮紅/耳內
            "W": 0xC9CDD4, // 胸口白斑
            "U": 0x7A5A3A, // 碗
            "T": 0x8A5A2B, // 零食
        ],
        animations: [
            .idle: [catIdleA, catIdleB],
            .walk: [catWalkA, catWalkB],
            .sit: [catIdleA, catIdleB],
            .sleep: [catSleepA, catSleepB],
            .eat: [catEatA, catEatB],
            .jump: [catJumpA, catIdleA],
        ]
    )

    static let catIdleA = [
        "....O.......O.......",
        "...OPO.....OPO......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        ".OBBBBBBBBBBBBBO....",
        ".OBEEBBBBBBEEBBO....",
        ".OBPBBBBSBBBBPBO....",
        ".OBBBBBBBBBBBBBO....",
        "OBBBBBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBOOOO.",
        "OBBBBBBBBBBBBBBOBBO.",
        "OBBBBBBBBBBBBBBOBBO.",
        ".OBBBBBBBBBBBBBOBO..",
        ".OBBOBBBBBBOBBOO....",
        "..OBBO..OBBO........",
        "....................",
    ]

    static let catIdleB = [
        "....O........O......",
        "...OPO.....OPO......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        ".OBBBBBBBBBBBBBO....",
        ".OBSSBBBBBBSSBBO....",
        ".OBPBBBBSBBBBPBO....",
        ".OBBBBBBBBBBBBBO....",
        "OBBBBBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBOOOO.",
        "OBBBBBBBBBBBBBBOBBO.",
        "OBBBBBBBBBBBBBBOBBO.",
        ".OBBBBBBBBBBBBBOBO..",
        ".OBBOBBBBBBOBBOO....",
        "..OBBO..OBBO........",
        "....................",
    ]

    static let catWalkA = [
        "....O.......O.......",
        "...OPO.....OPO......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        ".OBBBBBBBBBBBBBO....",
        ".OBEEBBBBBBEEBBO....",
        ".OBPBBBBSBBBBPBO....",
        ".OBBBBBBBBBBBBBO....",
        "OBBBBBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBOOOO.",
        "OBBBBBBBBBBBBBBOBBO.",
        "OBBBBBBBBBBBBBBOBBO.",
        ".OBBBBBBBBBBBBBOBO..",
        ".OBBOBBBBBBOBBOO....",
        "..OBBO...OBBO.......",
        "....................",
    ]

    static let catWalkB = [
        "....O.......O.......",
        "...OPO.....OPO......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        ".OBBBBBBBBBBBBBO....",
        ".OBEEBBBBBBEEBBO....",
        ".OBPBBBBSBBBBPBO....",
        ".OBBBBBBBBBBBBBO....",
        "OBBBBBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBOOOO.",
        "OBBBBBBBBBBBBBBOBBO.",
        "OBBBBBBBBBBBBBBOBBO.",
        ".OBBBBBBBBBBBBBOBO..",
        ".OBBOBBBBBBOBBOO....",
        "....OBBO...OBBO.....",
        "....................",
    ]

    static let catSleepA = [
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....OOOOOOOO........",
        "..OOBBBBBBBBOO......",
        ".OBBBBBBBBBBBBO.....",
        ".OBBSSBBBBSSBBO.....",
        ".OBBBBBBBBBBBBO.....",
        ".OBOBBBBBBBBOBO.....",
        "..OOBBBBBBBBOO......",
        "....OOOOOOOO........",
        "....................",
    ]

    static let catSleepB = [
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "....................",
        "...OOOOOOOOOO.......",
        "..OBBBBBBBBBBO......",
        ".OBBBBBBBBBBBBO.....",
        ".OBBSSBBBBSSBBO.....",
        ".OBBBBBBBBBBBBO.....",
        ".OBOBBBBBBBBOBO.....",
        "..OOBBBBBBBBOO......",
        "....OOOOOOOO........",
        "....................",
    ]

    /// 低頭吃碗(頭部下移一列、碗在腳前)
    static let catEatA = [
        "....................",
        "....O.......O.......",
        "...OPO.....OPO......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        ".OBBBBBBBBBBBBBO....",
        ".OBEEBBBBBBEEBBO....",
        ".OBPBBBBSBBBBPBO....",
        "OBBBBBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBOOOO.",
        "OBBBBBBBBBBBBBBOBBO.",
        ".OBBBBBBBBBBBBBOBO..",
        ".OBBOBBBBBBOBBOO....",
        "..OBBO..OBBO........",
        "......UWWWWU........",
        "......UUUUUU........",
    ]

    /// 咀嚼(闔眼、碗中食物變少)
    static let catEatB = [
        "....................",
        "....O.......O.......",
        "...OPO.....OPO......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        ".OBBBBBBBBBBBBBO....",
        ".OBSSBBBBBBSSBBO....",
        ".OBPBBBBSBBBBPBO....",
        "OBBBBBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBOOOO.",
        "OBBBBBBBBBBBBBBOBBO.",
        ".OBBBBBBBBBBBBBOBO..",
        ".OBBOBBBBBBOBBOO....",
        "..OBBO..OBBO........",
        "......U.WW.U........",
        "......UUUUUU........",
    ]

    static let catJumpA = [
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        ".OBBBBBBBBBBBBBO....",
        ".OBEEBBBBBBEEBBO....",
        ".OBPBBBBSBBBBPBO....",
        ".OBBBBBBBBBBBBBO....",
        "OBBBBBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBOOOO.",
        "OBBBBBBBBBBBBBBOBBO.",
        ".OBBBBBBBBBBBBBOBO..",
        ".OBBOBBBBBBOBBOO....",
        "..OBBO..OBBO........",
        "....................",
        "....................",
        "....................",
        "....................",
    ]
}

// MARK: - 心情徽章的像素字形(取代 emoji 疊標)

public enum PixelGlyphs {
    /// 每個字形:rows + 主色(0xRRGGBB)。'#' 為著色像素。
    public static let warning: (rows: [String], color: UInt32) = ([
        ".#.",
        ".#.",
        ".#.",
        "...",
        ".#.",
    ], 0xE05545)

    public static let confused: (rows: [String], color: UInt32) = ([
        "##.",
        "..#",
        ".#.",
        "...",
        ".#.",
    ], 0x9AA1AB)

    public static let hungry: (rows: [String], color: UInt32) = ([
        "#.#",
        "###",
        "###",
    ], 0xC98B4A)

    public static func glyph(for mood: PetMood) -> (rows: [String], color: UInt32)? {
        switch mood {
        case .warning, .exhausted: return warning
        case .confused: return confused
        case .hungry: return hungry
        default: return nil
        }
    }
}

// MARK: - Provider 短代號(選單列/寵物量表同時顯示多家用)

public func shortProviderCode(_ providerId: String) -> String {
    switch providerId {
    case "claude-code": return "CC"
    case "codex": return "CX"
    case "antigravity": return "AG"
    case "grok-code": return "GK"
    default: return String(providerId.prefix(2)).uppercased()
    }
}

// MARK: - 寵物台詞(像素對話泡泡用)

public enum PetSpeech {
    /// 進入該心情時自動說一句;nil = 不說話(睡覺不吵)。
    public static func phrases(for mood: PetMood) -> [String]? {
        switch mood {
        case .celebration: return ["WOW!", "quota reset!"]
        case .eating: return ["yum yum!", "nom nom!"]
        case .hungry: return ["feed me?", "treat plz!"]
        case .warning: return ["slow down!", "quota alert!"]
        case .exhausted: return ["out of juice…", "need a reset…"]
        case .confused: return ["huh?", "where's my data?"]
        case .happy: return ["wow!", "nice!"]
        case .idle, .focused, .tired, .sleeping: return nil
        }
    }
}

// MARK: - 寵物機制說明(tooltip 共用文案)

public enum PetInfo {
    public static let tooltip = """
    The pet mirrors your real AI usage — it is not a health or productivity tracker.
    • focused / idle / sleeping follow recent activity in your local logs
    • warning / exhausted mirror official 5h & weekly limit pressure
    • Lv & XP grow from real work (capped daily; no reward for burning tokens)
    • hunger is a care mechanic only — feed with treats earned by active work time
    """
}
