import Foundation

// 原創像素寵物圖(全部手工自繪,非複製任何素材)。
// 每幀為 height 列 × width 欄的字元網格:'.' 透明,其餘字元查 palette 取色。
// 美術以字串定義,方便直接在此檔調整造型。
//
// 風格語彙:
//   金毛 — 扁平無外框、大頭側面、垂耳+豎耳、黑方眼、粉色大舌、深項圈、方柱腿。
//   黑貓 — 胖圓一體、亮灰粗外框(深色桌面可見)、綠眼、粉腮紅、捲尾、正面坐姿。

public enum PixelAnimState: String, CaseIterable, Sendable {
    case idle, walk, sit, sleep, eat, jump
    /// 開心:狗搖尾+喘舌;貓尾尖搖擺。
    case happy
    /// 警戒(warning):狗豎耳坐姿;貓沿用坐姿(警示徽章表意)。
    case alert
    /// 貓進入專注的 one-shot 轉場(紅粉半瞇眼 → 綠眼張開、耳朵前傾)。
    case focusStart
    /// 貓專注迴圈:綠眼 + 亮 core 低頻 pulse。
    case focusedActive
    /// 貓退出專注的 one-shot 轉場(較短、較收斂,不得 hard cut)。
    case focusEnd
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

    /// mood(+ 是否正在漫遊行走)→ 動畫狀態。狀態切換一律由 mood 決定性驅動,
    /// 隨機只用於 idle micro-animation(spec:randomness is for personality)。
    public static func animState(for mood: PetMood, walking: Bool,
                                 species: PetSpecies = .dog) -> PixelAnimState {
        if walking, [.idle, .happy, .focused].contains(mood) { return .walk }
        switch mood {
        case .sleeping, .tired: return .sleep
        case .eating: return .eat
        case .celebration: return .jump
        case .focused: return species == .cat ? .focusedActive : .sit
        case .warning: return .alert
        case .exhausted, .hungry, .confused: return .sit
        case .idle: return .idle
        case .happy: return .happy
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
        case .happy: return 5           // 搖尾一輪 ~0.8s,位移限 1–3px
        case .alert: return 2           // 豎耳微顫
        case .focusStart: return 10     // 4 幀 ≈ 0.4s(spec 400–700ms)
        case .focusedActive: return 1.3 // 2 幀 → core pulse 週期 ≈ 1.5s(spec 1.2–1.8s)
        case .focusEnd: return 10       // 3 幀 ≈ 0.3s,比進場更快更收斂
        }
    }

    /// 進入某狀態時要先播的 one-shot 轉場(deterministic,由 mood 變化觸發)。
    public static func enterTransition(species: PetSpecies, to state: PixelAnimState) -> PixelAnimState? {
        if species == .cat, state == .focusedActive { return .focusStart }
        return nil
    }

    /// 離開某狀態時要先播的 one-shot 轉場(spec:focused 不得 hard cut 回 idle)。
    public static func exitTransition(species: PetSpecies, from state: PixelAnimState) -> PixelAnimState? {
        if species == .cat, state == .focusedActive { return .focusEnd }
        return nil
    }

    /// reduce-motion / quiet 模式的靜態代表姿勢:取該狀態第一幀
    /// (focusedActive 第一幀即「綠眼+耳朵前傾」,不播 pulse 也能讀出狀態)。
    public static func staticPose(sprite: PixelSprite, state: PixelAnimState) -> [String] {
        sprite.frames(for: state).first ?? []
    }

    // MARK: - 隨機 micro-animation(僅 personality,不承載狀態語意)

    public struct MicroAnimation: Sendable, Equatable {
        public let name: String
        public let frames: [[String]]
        public let fps: Double
        /// 播完後距下次觸發的隨機間隔(秒)。
        public let interval: ClosedRange<Double>
    }

    /// 各物種在「安靜 loop 狀態」下可插播的 micro-animation;
    /// walk / sleep / eat / jump 期間一律不插播。
    public static func microAnimations(species: PetSpecies, state: PixelAnimState) -> [MicroAnimation] {
        switch (species, state) {
        case (.dog, .idle), (.dog, .sit), (.dog, .alert):
            return [MicroAnimation(name: "earTwitch",
                                   frames: [dogEarTwitchA, dogEarTwitchA, dogIdleA],
                                   fps: 10, interval: 3...8)]
        case (.cat, .idle), (.cat, .sit), (.cat, .alert), (.cat, .happy):
            return [
                MicroAnimation(name: "blink",
                               frames: [catBlinkA, catBlinkA],
                               fps: 9, interval: 4...9),
                MicroAnimation(name: "tailFlick",
                               frames: [catTailFlickA, catTailFlickB],
                               fps: 6, interval: 3...6),
                MicroAnimation(name: "whiskerTwitch",
                               frames: [catWhiskerTwitchA, catIdleA],
                               fps: 8, interval: 4...8),
            ]
        case (.cat, .focusedActive):
            return [MicroAnimation(name: "whiskerTwitch",
                                   frames: [catFocusWhiskerA, catFocusedActiveA],
                                   fps: 8, interval: 4...8)]
        default:
            return []
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
            // 開心:尾巴三段位置(尾根固定)+ 喘舌長短交替(spec §dog tail wag / tongue panting)
            .happy: [dogHappyA, dogHappyB, dogHappyC, dogHappyB],
            // 警戒:坐姿豎耳微顫;像素驚嘆號由徽章層以整數位移彈跳
            .alert: [dogAlertA, dogAlertA, dogAlertB],
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

    /// 躍起接零食:頭部維持 idle 列位(耳尖/眉,idle 第 0–1 列完整保留)——舊版把全身
    /// 上移 2 列,耳尖掉出 18 列網格頂(使用者回報「餵食後頭被切」),與 dogJumpA 同一
    /// bug class(R3 修了跳躍卻漏了進食)。改以「收腿 + 底部騰空列」表現離地,零食漂浮
    /// 於頭部右上(第 1–2 列)。內容 = dogJumpA + 零食(T)。
    static let dogEatA = [
        ".............AA.....",
        ".....MM.....AAAA.TT.",
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
    // 跳躍:頭部(含耳尖/眉,idle 第 0–1 列)完整保留 —— 舊版把全身上移 2 列,
    // 耳尖掉出網格頂(使用者回報「餵食跳起來耳朵被切」)。改以「收腿 + 底部騰空列」
    // 表現離地:身體 = idle 原位,腿收攏、底下 2 列留空。
    static let dogJumpA = [
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
        "....AAAA..AAAA......",
        "....................",
        "....................",
    ]

    /// 開心搖尾:尾巴高位 + 長舌喘氣(尾根固定於身體接點,位移 ≤2px)
    static let dogHappyA = [
        ".............AA.....",
        ".....MM.....AAAA....",
        "....MMMMAAAAAAAA....",
        "....MMMAAAAAAAAAA...",
        ".....MMAAAAAAKKAA...",
        ".......AAAAAAKKAAKK.",
        "AA.....AAAAAAAAAAKK.",
        "AAA....AAAAAAAAAA...",
        ".AA....AAAAAAAAPPPP.",
        ".......KKKKKKKK.PPP.",
        "...AAAAAAAAAAAA.PP..",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAAAAA.....",
        "..AAAAAAAAAAAAA.....",
        "...AACAACAACAA......",
        "...AA.AA.AA.AA......",
        "....................",
    ]

    /// 開心搖尾:尾巴中位(idle 位置)+ 短舌
    static let dogHappyB = [
        ".............AA.....",
        ".....MM.....AAAA....",
        "....MMMMAAAAAAAA....",
        "....MMMAAAAAAAAAA...",
        ".....MMAAAAAAKKAA...",
        ".......AAAAAAKKAAKK.",
        ".......AAAAAAAAAAKK.",
        "AA.....AAAAAAAAAA...",
        "AAA....AAAAAAAAPP...",
        ".AA....KKKKKKKK.P...",
        "...AAAAAAAAAAAA.....",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAAAAA.....",
        "..AAAAAAAAAAAAA.....",
        "...AACAACAACAA......",
        "...AA.AA.AA.AA......",
        "....................",
    ]

    /// 開心搖尾:尾巴低位 + 長舌
    static let dogHappyC = [
        ".............AA.....",
        ".....MM.....AAAA....",
        "....MMMMAAAAAAAA....",
        "....MMMAAAAAAAAAA...",
        ".....MMAAAAAAKKAA...",
        ".......AAAAAAKKAAKK.",
        ".......AAAAAAAAAAKK.",
        ".......AAAAAAAAAA...",
        "AA.....AAAAAAAAPPPP.",
        "AAA....KKKKKKKK.PPP.",
        "AA.AAAAAAAAAAAA.PP..",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAACCC.....",
        "..AAAAAAAAAAAAA.....",
        "..AAAAAAAAAAAAA.....",
        "...AACAACAACAA......",
        "...AA.AA.AA.AA......",
        "....................",
    ]

    /// 耳朵抽動(micro-animation):單耳向上/向後 1px,hold 後回復
    static let dogEarTwitchA = [
        "....MM.......AA.....",
        "....MM......AAAA....",
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

    /// 警戒:坐姿 + 雙耳前豎(垂耳抬起),舌頭收起
    static let dogAlertA = [
        "....MM.......AA.....",
        "....MMM.....AAAA....",
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

    /// 警戒:耳尖右移 1px 的微顫幀
    static let dogAlertB = [
        ".....MM......AA.....",
        "....MMM.....AAAA....",
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

    // MARK: - Black Cat(20×18,正面坐姿胖圓、亮灰外框、綠眼、粉腮紅)

    static let blackCat = PixelSprite(
        width: 20,
        height: 18,
        palette: [
            "O": 0x707887, // 外框(深色桌面可見)
            "B": 0x262A31, // 身體
            "S": 0x3D434E, // 條紋/闔眼線
            "E": 0x7FE08A, // 綠眼(僅 focused 狀態)
            "G": 0xB9F6C3, // 專注亮綠 core(pulse 用)
            "D": 0x4E8A5A, // 專注轉場暗綠
            "R": 0xC96A72, // 常態紅粉半瞇眼(spec:綠眼不得是辨識貓的唯一線索)
            "P": 0xE08BA8, // 腮紅/耳內
            "W": 0xC9CDD4, // 胸口白斑/鬍鬚
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
            // 開心:尾尖搖擺(貓比狗安靜,只動尾巴)
            .happy: [catIdleA, catTailFlickA, catIdleB, catTailFlickB],
            // 警戒:坐姿(徽章表意;貓不做大動作)
            .alert: [catIdleA, catIdleB],
            // 進入專注:紅粉眼睜大 → 暗綠 → 綠眼全開+耳朵前傾 → 亮 core(≈0.4s)
            .focusStart: [catFocusStartA, catFocusStartB, catFocusStartC, catFocusedActiveA],
            // 專注迴圈:core 亮/暗低頻 pulse(週期 ≈1.5s)
            .focusedActive: [catFocusedActiveA, catFocusedActiveB],
            // 退出專注:core 熄 → 暗綠+耳朵回位 → 回常態(≈0.3s,比進場收斂)
            .focusEnd: [catFocusedActiveB, catFocusEndB, catIdleA],
        ]
    )

    // 常態(common):紅粉半瞇眼 + 左右鬍鬚;眨眼改由 micro-animation 排程
    // (舊版以 idleB 闔眼 1.4fps 交替 ≈ 每 0.7s 眨一次,遠超 spec 的 4–9s)。
    static let catIdleA = [
        "....O.......O.......",
        "...OPO.....OPO......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        ".OBBBBBBBBBBBBBO....",
        "WOBRRBBBBBBRRBBOWW..",
        ".OBPBBBBSBBBBPBO....",
        "WOBBBBBBBBBBBBBOW...",
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

    /// 呼吸幀:胸口白斑下移 1px(吐氣),眼睛不變——眨眼獨立排程
    static let catIdleB = [
        "....O.......O.......",
        "...OPO.....OPO......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        ".OBBBBBBBBBBBBBO....",
        "WOBRRBBBBBBRRBBOWW..",
        ".OBPBBBBSBBBBPBO....",
        "WOBBBBBBBBBBBBBOW...",
        "OBBBBBBBBBBBBBBBO...",
        "OBBBBBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBOOOO.",
        "OBBWWBBBBBBBBBBOBBO.",
        "OBBBBBBBBBBBBBBOBBO.",
        ".OBBBBBBBBBBBBBOBO..",
        ".OBBOBBBBBBOBBOO....",
        "..OBBO..OBBO........",
        "....................",
    ]

    /// 眨眼(micro-animation):闔眼一瞬
    static let catBlinkA = [
        "....O.......O.......",
        "...OPO.....OPO......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        ".OBBBBBBBBBBBBBO....",
        "WOBSSBBBBBBSSBBOWW..",
        ".OBPBBBBSBBBBPBO....",
        "WOBBBBBBBBBBBBBOW...",
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

    /// 鬍鬚抽動(micro-animation):鬍鬚整組上移 1px
    static let catWhiskerTwitchA = [
        "....O.......O.......",
        "...OPO.....OPO......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        "WOBBBBBBBBBBBBBOWW..",
        ".OBRRBBBBBBRRBBO....",
        "WOBPBBBBSBBBBPBOW...",
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

    /// 尾尖外甩(micro-animation / happy 用):只有尾尖 1–2px 動
    static let catTailFlickA = [
        "....O.......O.......",
        "...OPO.....OPO......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        ".OBBBBBBBBBBBBBO....",
        "WOBRRBBBBBBRRBBOWW..",
        ".OBPBBBBSBBBBPBO....",
        "WOBBBBBBBBBBBBBOW...",
        "OBBBBBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBOOOO.",
        "OBBBBBBBBBBBBBBOBBO.",
        "OBBBBBBBBBBBBBBOBBO.",
        ".OBBBBBBBBBBBBBOBBO.",
        ".OBBOBBBBBBOBBOO.O..",
        "..OBBO..OBBO........",
        "....................",
    ]

    /// 尾尖內收(micro-animation / happy 用)
    static let catTailFlickB = [
        "....O.......O.......",
        "...OPO.....OPO......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        ".OBBBBBBBBBBBBBO....",
        "WOBRRBBBBBBRRBBOWW..",
        ".OBPBBBBSBBBBPBO....",
        "WOBBBBBBBBBBBBBOW...",
        "OBBBBBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBOOOO.",
        "OBBBBBBBBBBBBBBOBBO.",
        "OBBBBBBBBBBBBBBOBO..",
        ".OBBBBBBBBBBBBBOBO..",
        ".OBBOBBBBBBOBBOO....",
        "..OBBO..OBBO........",
        "....................",
    ]

    /// 專注轉場 1:紅粉眼睜大(1px → 2px)
    static let catFocusStartA = [
        "....O.......O.......",
        "...OPO.....OPO......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        ".OBRRBBBBBBRRBBO....",
        "WOBRRBBBBBBRRBBOWW..",
        ".OBPBBBBSBBBBPBO....",
        "WOBBBBBBBBBBBBBOW...",
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

    /// 專注轉場 2:紅粉 → 暗綠
    static let catFocusStartB = [
        "....O.......O.......",
        "...OPO.....OPO......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        ".OBDDBBBBBBDDBBO....",
        "WOBDDBBBBBBDDBBOWW..",
        ".OBPBBBBSBBBBPBO....",
        "WOBBBBBBBBBBBBBOW...",
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

    /// 專注轉場 3:綠眼全開 + 耳朵前傾 1px
    static let catFocusStartC = [
        ".....O.....O........",
        "....OPO...OPO.......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        "WOBRRBBBBBBRRBBOWW..",
        "WOBEEBBBBBBEEBBOWW..",
        ".OBPBBBBSBBBBPBO....",
        "WOBBBBBBBBBBBBBOW...",
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

    /// 專注迴圈 A:綠眼 + 內側亮 core(pulse 亮相)
    static let catFocusedActiveA = [
        ".....O.....O........",
        "....OPO...OPO.......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        "WOBRRBBBBBBRRBBOWW..",
        "WOBEGBBBBBBGEBBOWW..",
        ".OBPBBBBSBBBBPBO....",
        "WOBBBBBBBBBBBBBOW...",
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

    /// 專注迴圈 B:core 熄(pulse 暗相)
    static let catFocusedActiveB = [
        ".....O.....O........",
        "....OPO...OPO.......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        "WOBRRBBBBBBRRBBOWW..",
        "WOBEEBBBBBBEEBBOWW..",
        ".OBPBBBBSBBBBPBO....",
        "WOBBBBBBBBBBBBBOW...",
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

    /// 退出專注中段:暗綠 + 耳朵回位
    static let catFocusEndB = [
        "....O.......O.......",
        "...OPO.....OPO......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        ".OBDDBBBBBBDDBBO....",
        "WOBDDBBBBBBDDBBOWW..",
        ".OBPBBBBSBBBBPBO....",
        "WOBBBBBBBBBBBBBOW...",
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

    /// 專注中的鬍鬚抽動(micro-animation):鬍鬚下移 1px,眼睛維持綠眼+core
    static let catFocusWhiskerA = [
        ".....O.....O........",
        "....OPO...OPO.......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        "WOBRRBBBBBBRRBBOWW..",
        ".OBEGBBBBBBGEBBO....",
        "WOBPBBBBSBBBBPBOW...",
        "WOBBBBBBBBBBBBBOW...",
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
        "WOBRRBBBBBBRRBBOWW..",
        ".OBPBBBBSBBBBPBO....",
        "WOBBBBBBBBBBBBBOW...",
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
        "WOBRRBBBBBBRRBBOWW..",
        ".OBPBBBBSBBBBPBO....",
        "WOBBBBBBBBBBBBBOW...",
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
        "WOBRRBBBBBBRRBBOWW..",
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
        "WOBSSBBBBBBSSBBOWW..",
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

    /// 慶祝跳躍:頭部維持 idle 列位(耳尖,idle 第 0–1 列完整保留)——舊版把全身上移
    /// 2 列,貓耳尖掉出網格頂(與 dogEatA/dogJumpA 同 bug class;R3「貓不受影響」對跳躍
    /// 誤判)。改以「收腳 + 底部騰空列」表現離地。內容 = catIdleA 前 15 列 + 收起的腳。
    static let catJumpA = [
        "....O.......O.......",
        "...OPO.....OPO......",
        "...OBBO...OBBO......",
        "..OBBBBBBBBBBBO.....",
        "..OBBSBBBBBSBBO.....",
        ".OBBBBBBBBBBBBBO....",
        "WOBRRBBBBBBRRBBOWW..",
        ".OBPBBBBSBBBBPBO....",
        "WOBBBBBBBBBBBBBOW...",
        "OBBBBBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBBO...",
        "OBBWWBBBBBBBBBBOOOO.",
        "OBBBBBBBBBBBBBBOBBO.",
        "OBBBBBBBBBBBBBBOBBO.",
        ".OBBBBBBBBBBBBBOBO..",
        "..OBBO..OBBO........",
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
    • fullness is a care mechanic only — feed with treats earned by active work time
    """
}
