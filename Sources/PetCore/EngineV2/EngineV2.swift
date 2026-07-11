import Foundation
import CoreGraphics

/// EngineV2 總開關與 **packet 凍結** 常數(M2 計畫 §5/§6)。
///
/// - `isEnabled` 預設 `false`:flag 關 = 既有行為位元不變(硬閘)。
///   E0/E1 無 UI 接線,僅供程式/偵錯切換;app 端由 PetPanelController 讀取。
/// - 本型別**只收 packet 凍結值**(E0 可比性;golden set A 由此手算,一字不改;
///   誤調會被 testFrozenConstants 與 golden set A 擋下)。
/// - 實作**自選**(packet 未凍結、可依 feel-test 重調)的調參一律放檔尾 `V2Tuning`
///   —— 凍結 vs 自選嚴格分家(E1 取法 A 案的 tuning 分區)。
public enum EngineV2 {

    /// petEngineV2 功能旗標。預設關;關閉時 Bridge/新引擎完全不啟動。
    public static var isEnabled = false

    // MARK: - §5 凍結常數(凍結;E0 可比性,一字不改)

    /// 重力加速度(px/s²;AppKit 座標 +y 向上,重力向下)。
    public static let gravity: CGFloat = 900
    /// 空中線性減速(px/s²)。
    public static let airDecel: CGFloat = 120
    /// 地面接觸線性減速(px/s²)。
    public static let groundDecel: CGFloat = 450
    /// 水中線性減速(px/s²)。
    public static let waterDecel: CGFloat = 300
    /// Walker 巡航目標速度(px/s)。
    public static let walkerCruise: CGFloat = 36
    /// Flyer 拍翅 one-shot 衝量(px/s,+y 向上)。
    public static let flapImpulse: CGFloat = 220
    /// Swimmer 漂游目標速度(px/s)。
    public static let swimmerDrift: CGFloat = 24
    /// 彈跳能量係數(側緣反彈 / 中等落地反彈)。
    public static let bounceEnergy: CGFloat = 0.55
    /// 歐氏逃逸速度帽(px/s;無軸速帽)。
    public static let escapeSpeedCap: CGFloat = 600
    /// dt 夾限上限(秒;喚醒/重配置後的大 dt 防護)。
    public static let dtCap: TimeInterval = 0.25
    /// 拖曳判定:位移下限(px)。
    public static let dragMinDistance: CGFloat = 4
    /// 拖曳判定:持續時間下限(秒)。
    public static let dragMinDuration: TimeInterval = 0.12

    /// 點擊 vs 拖曳判定(§5:≥4px 且 ≥120ms)。
    public static func isDrag(distance: CGFloat, duration: TimeInterval) -> Bool {
        distance >= dragMinDistance && duration >= dragMinDuration
    }

    // MARK: - overlay 觸發對照(§3-D;E0 僅 working1 一態接線示範)

    /// 近期活動 burn 檔位:0 = 無(超過 60s 無事件),1/2/3 = [0, 0.5M) / [0.5M, 5M) / [5M, ∞) tokens/h。
    /// 全部輸入為既有正規化欄位(lastEventAt 距今秒數、burnRateTokensPerHour)。
    /// 檔位邊界 E0 凍結(半開區間;E1+ 依 feel 調屬 §3-D 條款,調整時同步改此註記)。
    public static func workingTier(secondsSinceLastEvent: TimeInterval, tokensPerHour: Double) -> Int {
        guard secondsSinceLastEvent >= 0, secondsSinceLastEvent <= 60 else { return 0 }
        if tokensPerHour < 500_000 { return 1 }
        if tokensPerHour < 5_000_000 { return 2 }
        return 3
    }
}

/// 實作**自選**調參(E1 取法 A 案:凍結 vs 自選分家)。
///
/// 收錄 packet **未**凍結、golden set 不觸及的定性參數(著地分級門檻、懸停餘裕、
/// 幀節奏等)。E1+ 可依 feel-test 自由重調;§5 凍結值永遠不得搬進來。
/// 全部為原創手調數值(授權防線:非任何參考專案之預設值)。
enum V2Tuning {

    // MARK: - 自選(著地反應;§7 僅定性必過,無 ±0)

    /// 著地衝擊分級門檻(px/s):|v.y| < soft 軟著地;[soft, bounce) 反彈(×0.55);≥ bounce 重落。
    static let softLandingSpeed: CGFloat = 180
    static let bounceLandingSpeed: CGFloat = 450

    // MARK: - 自選(Flyer 懸停)

    /// 懸停煞車餘裕(px):加在單 tick 最大下墜行程之上,吸收離散 tick 的過衝。
    static let hoverFlapMargin: CGFloat = 6

    // MARK: - 自選(呈現節奏)

    /// 每幀時長(秒;E0/E1 佔位節奏,pack 級 fps 屬 E2+ 美術管線)。
    static let frameDuration: TimeInterval = 0.15
}
