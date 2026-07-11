import Foundation
import CoreGraphics

// MARK: - 點擊 vs 拖曳手勢辨識(E1 取法 A 案:辨識與物理分離)

/// 拖曳手勢辨識器 — 把「≥4px 且 ≥120ms」(§5 凍結)的**判定狀態機**從物理層抽成獨立型別:
/// Bridge 把滑鼠事件餵進來,`isDragging` 轉真後才呼叫 `MotionControlling.beginDrag`
/// (未達門檻的按放 = 點擊,不進拖曳車道)。
///
/// 語意:
/// - 位移取「離按下點的**歷史最大**距離」:曾拖遠再拖回也算拖曳(不會中途退回點擊)。
/// - 兩條件(距離、時間)皆含等號;判定式本體沿用 `EngineV2.isDrag`(凍結門檻單一出處)。
/// - 一旦達標,`isDragging` 保持 true 直到 `ended()`;`began` 重置整個手勢。
public struct DragRecognizer: Sendable {
    private var origin: CGPoint?
    private var startTime: TimeInterval = 0
    private var maxDistance: CGFloat = 0
    /// 目前手勢是否已判定為拖曳(sticky:達標後維持到 ended)。
    public private(set) var isDragging = false

    public init() {}

    /// 按下:記錄原點與起始時刻,重置手勢狀態。
    public mutating func began(at point: CGPoint, time: TimeInterval) {
        origin = point
        startTime = time
        maxDistance = 0
        isDragging = false
    }

    /// 移動:更新歷史最大位移並套用凍結判定。回傳目前是否已達拖曳門檻。
    /// 未曾 `began` 的移動一律不判定(回 false)。
    @discardableResult
    public mutating func moved(to point: CGPoint, time: TimeInterval) -> Bool {
        guard let origin else { return false }
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        maxDistance = max(maxDistance, (dx * dx + dy * dy).squareRoot())
        if EngineV2.isDrag(distance: maxDistance, duration: time - startTime) {
            isDragging = true
        }
        return isDragging
    }

    /// 放開:結束手勢並重置(呼叫端在此之前讀 `isDragging` 分流點擊/放手甩出)。
    public mutating func ended() {
        origin = nil
        startTime = 0
        maxDistance = 0
        isDragging = false
    }
}
