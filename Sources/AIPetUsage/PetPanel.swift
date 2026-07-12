import AppKit
import SwiftUI
import UsageCore
import PetCore

/// 漂浮寵物視窗:無邊框、透明、置頂、可拖曳、跨 Spaces,位置持久化。
/// 選配「螢幕漫遊」:閒置時沿螢幕底部走動(可關閉、遵守減少動態偏好)。
@MainActor
final class PetPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private weak var model: AppModel?
    private var wanderTask: Task<Void, Never>?
    /// petEngineV2 flag 開啟時的新引擎 Bridge;flag 關(預設)完全不建立。
    private var engineV2Driver: EngineV2Driver?
    /// 手動拖曳的位置持久化去抖:每個 windowDidMove 取消上一個,拖曳靜止後才寫一次 settings.json。
    private var positionSaveTask: Task<Void, Never>?
    /// 漫遊位移期間為 true,windowDidMove 據此略過位置持久化(避免每秒十餘次寫檔)。
    var isWanderMoving = false   // internal:EngineV2Driver(30Hz origin 寫入)沿用同一抑制旗標(FIX-7)
    private var wanderHeading: Int = 1
    private var wanderPhaseUntil: Date = .distantPast
    /// 漫遊範圍帶的 home(寵物中心 x;A1/D4):於漫遊開啟、拖曳落定、app 啟動、
    /// 範圍變更時重錨;不持久化(重啟以還原位置重錨)。V2 driver 亦讀此值收窄 RegionMap。
    private(set) var wanderHomeCenterX: CGFloat?
    private var lastWanderEnabled = false
    /// 使用者拖曳中(R2 B4):willMove(僅使用者拖曳觸發)設起,漫遊 tick 全停;
    /// 拖曳落定去抖清除。failsafe:willMove 後零 didMove(按住不動)3s 自清,
    /// 不得永久卡死漫遊。
    private var userDragActive = false
    private var userDragFailsafeAt: Date = .distantPast

    init(model: AppModel) {
        self.model = model
        super.init()
        // 去抖後直接 ⌘Q 退出時,400ms 排程可能還沒落地就遺失最後位置;
        // termination path 不會走 destroy(),故在此於 quit 前同步補寫一次。
        NotificationCenter.default.addObserver(
            self, selector: #selector(flushPositionOnTerminate),
            name: NSApplication.willTerminateNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // willTerminate 於主執行緒同步發送,直接同步落地目前位置(不經過去抖排程)。
    @objc private func flushPositionOnTerminate() {
        persistPositionNow()
    }

    private func makePanel() -> NSPanel {
        let size = panelSize()
        let panel = NSPanel(contentRect: NSRect(origin: restoreOrigin(for: size), size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = model?.settings.clickThrough ?? false // 首次建立就套用
        panel.delegate = self
        if let model {
            let host = NSHostingView(rootView: PetView().environment(model))
            host.frame = NSRect(origin: .zero, size: size)
            panel.contentView = host
        }
        return panel
    }

    /// 泡泡保留區(R3,雙審裁定 A:泡泡完全在環圈之上):page 0 至多 4 行 11pt mono
    /// ≈78pt,取 92 留餘裕;字級不隨 petSize 縮放 → 固定 pt。常駐加高(勿隨泡泡
    /// show/hide 改尺寸 → 寵物跳)。
    static let bubbleReserve: CGFloat = 92

    private func panelSize() -> NSSize {
        let base = model?.settings.petSize ?? 96
        // R2 B1/B3:面板須容納 4 環容量外徑 + 邊距;R3:再加泡泡保留區(視窗透明,向上長)。
        let capD = UsageRingModel.capacityOuterDiameter(petSize: base)
        return NSSize(width: max(base * 2.6, capD + 12),
                      height: max(base * 2.0, capD + 14) + Self.bubbleReserve)
    }

    private func restoreOrigin(for size: NSSize) -> NSPoint {
        let mainVisible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let defaultOrigin = NSPoint(x: mainVisible.maxX - size.width - 24, y: mainVisible.minY + 24)
        guard let x = model?.settings.petPositionX, let y = model?.settings.petPositionY else {
            return defaultOrigin
        }
        // 夾限到目前仍存在的螢幕:外接螢幕拔除後,舊座標可能整個落在所有螢幕之外。
        // 跨兩螢幕時挑「交集面積最大」的螢幕(避免 first(where:) 依 screens 順序選錯,
        // 把仍可見於次螢幕的位置誤夾回主螢幕);全落在所有螢幕之外才退回預設角落。
        let savedRect = NSRect(origin: NSPoint(x: x, y: y), size: size)
        func overlapArea(_ vf: NSRect) -> CGFloat {
            let r = vf.intersection(savedRect)
            return r.isNull ? 0 : r.width * r.height
        }
        guard let vf = NSScreen.screens.map(\.visibleFrame).max(by: { overlapArea($0) < overlapArea($1) }),
              overlapArea(vf) > 0 else {
            return defaultOrigin
        }
        let clampedX = min(max(x, vf.minX), max(vf.minX, vf.maxX - size.width))
        let clampedY = min(max(y, vf.minY), max(vf.minY, vf.maxY - size.height))
        return NSPoint(x: clampedX, y: clampedY)
    }

    func show() {
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
        if wanderHomeCenterX == nil { reanchorWanderHome() }  // (c) 啟動:錨定 + 帶內夾限
        restartWanderLoop()
        if EngineV2.isEnabled, let panel {
            if engineV2Driver == nil { engineV2Driver = EngineV2Driver(panel: panel, model: model, controller: self) }
            engineV2Driver?.start()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        stopWanderLoop()
        engineV2Driver?.stop()
    }

    func destroy() {
        stopWanderLoop()
        engineV2Driver?.stop()
        engineV2Driver = nil
        // teardown 前一律補寫最後位置(grok P2-1):V2 deep-idle 已停表、或拖曳去抖
        // 未落地等路徑,條件式補寫都可能漏;無條件寫一次冪等且最保險。
        persistPositionNow()
        positionSaveTask?.cancel()
        positionSaveTask = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
    }

    func apply(settings: AppSettings) {
        guard let panel else {
            // panel 未建也要同步開關快照,否則啟動後首次 apply 會把「本來就開」
            // 誤判成 off→on 而多做一次重錨(codex P2)。
            lastWanderEnabled = settings.petWanderEnabled
            if settings.petVisible { show() }
            return
        }
        // (a) 漫遊由關轉開 → 重錨 + 帶內夾限。
        let wanderJustEnabled = settings.petWanderEnabled && !lastWanderEnabled
        lastWanderEnabled = settings.petWanderEnabled
        panel.ignoresMouseEvents = settings.clickThrough
        let newSize = panelSize()
        var sizeChanged = false
        // R3(codex):寬**或**高變更都要 resize(泡泡保留區只動高度,舊的 width-only
        // 比較會漏);resize 後把 origin 夾回目前螢幕(視窗變高可能頂出上緣)。
        if abs(panel.frame.width - newSize.width) > 1 || abs(panel.frame.height - newSize.height) > 1 {
            var frame = panel.frame
            frame.size = newSize
            if let vf = (panel.screen ?? NSScreen.main)?.visibleFrame {
                frame.origin.y = min(max(frame.origin.y, vf.minY), max(vf.minY, vf.maxY - newSize.height))
                frame.origin.x = min(max(frame.origin.x, vf.minX), max(vf.minX, vf.maxX - newSize.width))
            }
            panel.setFrame(frame, display: true)
            panel.contentView?.frame = NSRect(origin: .zero, size: newSize)
            sizeChanged = true
        }
        if wanderJustEnabled || sizeChanged {
            // 開關轉開或寵物尺寸改變:帶的 origin 轉換與 V2 收窄輸入都變 →
            // 走完整「重錨 + 帶內夾限 + V2 同步重算」(grok R2 P3:size 路徑不抄近路)。
            reanchorWanderHome()
        }
        if settings.petVisible { show() } else { hide() }
        restartWanderLoop()
    }

    /// 使用者開始拖曳視窗(AppKit:willMove 由使用者拖曳觸發;程式 setFrameOrigin
    /// 只發 didMove)。同步讀旗標(R2 B4/codex:不得走 async Task,程式性移動的
    /// isWanderMoving 包夾窗口極短,晚讀必誤判)。V2 完全不動(E3 已揭露回彈)。
    nonisolated func windowWillMove(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !isWanderMoving, !EngineV2.isEnabled else { return }
            userDragActive = true
            userDragFailsafeAt = Date().addingTimeInterval(3)
            model?.setWanderDirection(0)
        }
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            guard let panel = self.panel, !self.isWanderMoving else { return }
            // 拖曳持續中:順延 failsafe(每個使用者 move 事件都證明拖曳還活著)。
            if self.userDragActive {
                self.userDragFailsafeAt = Date().addingTimeInterval(3)
            }
            // 去抖:拖曳期間每個 move 事件取消上一個排程,靜止 0.4s 後才寫一次 settings.json。
            let origin = panel.frame.origin
            self.positionSaveTask?.cancel()
            self.positionSaveTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                self?.model?.savePetPosition(origin)
                // (b) 手動拖曳落定 → 統一重錨(帶隨放置點走,必為帶內;V2 同步重算)。
                self?.reanchorWanderHome()
                // R2 B4:恢復漫遊並顯式進入 2–6s 停走相位 — 放手後原地站一會兒才走。
                // 以 userDragActive 閘控(grok P3-1):漫遊自身的「走→停」落定不得重抽相位。
                if self?.userDragActive == true {
                    self?.userDragActive = false
                    self?.model?.setWanderDirection(0)
                    self?.wanderPhaseUntil = Date().addingTimeInterval(.random(in: 2...6))
                }
                self?.positionSaveTask = nil // 完成後清空,destroy() 才不會把已落地的 task 誤判為 pending
            }
        }
    }

    // MARK: - 漫遊迴圈

    private func stopWanderLoop() {
        wanderTask?.cancel()
        wanderTask = nil
        model?.setWanderDirection(0)
    }

    private func restartWanderLoop() {
        stopWanderLoop()
        guard !EngineV2.isEnabled else { return }   // flag 開:舊 wander 停用,運動交給 EngineV2
        guard model?.settings.petWanderEnabled == true else { return }
        wanderTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 90_000_000) // ~11 Hz,CPU 影響可忽略
                await self?.wanderTick()
            }
        }
    }

    private func wanderTick() {
        // R2 B4:使用者拖曳中全停(failsafe:willMove 後零 didMove 的按住不動 3s 自清)。
        if userDragActive {
            if Date() > userDragFailsafeAt { userDragActive = false } else { return }
        }
        guard let model, let panel, panel.isVisible else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let moodOK = [.idle, .happy, .focused].contains(model.mood.mood)
        guard model.settings.appMode == .full,
              model.settings.petWanderEnabled,
              !model.settings.quietMode,
              !reduceMotion,
              moodOK
        else {
            model.setWanderDirection(0)
            return
        }

        let now = Date()
        if now >= wanderPhaseUntil {
            // 走 3–8 秒、停 2–6 秒交替,方向隨機
            if model.wanderDirection == 0 {
                wanderHeading = Bool.random() ? 1 : -1
                model.setWanderDirection(wanderHeading)
                wanderPhaseUntil = now.addingTimeInterval(.random(in: 3...8))
            } else {
                model.setWanderDirection(0)
                wanderPhaseUntil = now.addingTimeInterval(.random(in: 2...6))
            }
        }
        guard model.wanderDirection != 0 else { return }

        guard let screen = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var origin = panel.frame.origin
        origin.x += CGFloat(wanderHeading) * 1.4
        // 漫遊範圍帶(A1):home ± range%×螢幕寬,center-x 語意 → origin 轉換。
        let band = WanderBand.centerBand(homeCenterX: wanderHomeCenterX ?? panel.frame.midX,
                                         rangePercent: model.settings.petWanderRangePercent,
                                         screen: screen, petWidth: panel.frame.width)
        let originBand = WanderBand.originRange(centerBand: band, petWidth: panel.frame.width)
        if origin.x <= originBand.lowerBound || origin.x >= originBand.upperBound {
            wanderHeading *= -1
            model.setWanderDirection(wanderHeading)
            origin.x = min(max(origin.x, originBand.lowerBound), originBand.upperBound)
        }
        isWanderMoving = true
        panel.setFrameOrigin(origin)
        isWanderMoving = false
    }

    /// 統一的「重錨 + 帶內夾限」(codex P2:四個觸發點 (a)–(d) 共用):
    /// 以當下位置重錨 home;home 可能被 centerBand 夾進螢幕可行區,帶外(貼緣放置)
    /// 則一次性 clamp 回帶內並保存;V2 引擎同步重算收窄帶(不等 Observation)。
    func reanchorWanderHome() {
        guard let panel, let model else { return }
        wanderHomeCenterX = panel.frame.midX
        if let screen = (panel.screen ?? NSScreen.main)?.visibleFrame {
            let band = WanderBand.centerBand(homeCenterX: panel.frame.midX,
                                             rangePercent: model.settings.petWanderRangePercent,
                                             screen: screen, petWidth: panel.frame.width)
            // home 本身也夾進帶(貼緣放置時 centerBand 已把可行區夾窄)。
            wanderHomeCenterX = min(max(panel.frame.midX, band.lowerBound), band.upperBound)
            let originBand = WanderBand.originRange(centerBand: band, petWidth: panel.frame.width)
            let clampedX = min(max(panel.frame.origin.x, originBand.lowerBound), originBand.upperBound)
            if clampedX != panel.frame.origin.x {
                isWanderMoving = true   // 程序性移動:抑制 windowDidMove 的持久化去抖
                panel.setFrameOrigin(NSPoint(x: clampedX, y: panel.frame.origin.y))
                isWanderMoving = false
                model.savePetPosition(panel.frame.origin)
            }
        }
        engineV2Driver?.wanderBandDidChange()
    }

    /// 漫遊結束/隱藏時保存最後位置。
    func persistPositionNow() {
        guard let panel else { return }
        model?.savePetPosition(panel.frame.origin)
    }
}

// MARK: - 像素渲染

/// 以 Canvas 最近鄰縮放繪製像素幀;deterministic、無外部資源。
struct PixelFrameView: View {
    let rows: [String]
    let palette: [Character: UInt32]
    let gridWidth: Int
    let gridHeight: Int
    var flipped = false

    var body: some View {
        Canvas { context, size in
            let cols = CGFloat(gridWidth)
            let lines = CGFloat(gridHeight)
            let cell = min(size.width / cols, size.height / lines)
            let xInset = (size.width - cell * cols) / 2
            let yInset = (size.height - cell * lines) / 2
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    guard let rgb = palette[ch] else { continue }
                    let drawX = flipped ? (cols - 1 - CGFloat(x)) : CGFloat(x)
                    let rect = CGRect(x: xInset + drawX * cell,
                                      y: yInset + CGFloat(y) * cell,
                                      width: cell + 0.5, height: cell + 0.5)
                    context.fill(Path(rect), with: .color(color(rgb)))
                }
            }
        }
    }

    private func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255,
              green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255)
    }
}

/// 心情徽章(像素字形,非 emoji),帶輕微閃爍。
struct PixelGlyphView: View {
    let glyph: (rows: [String], color: UInt32)

    var body: some View {
        Canvas { context, size in
            let cols = CGFloat(glyph.rows.map(\.count).max() ?? 1)
            let lines = CGFloat(glyph.rows.count)
            let cell = min(size.width / cols, size.height / lines)
            let c = Color(red: Double((glyph.color >> 16) & 0xFF) / 255,
                          green: Double((glyph.color >> 8) & 0xFF) / 255,
                          blue: Double(glyph.color & 0xFF) / 255)
            for (y, row) in glyph.rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    context.fill(Path(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell,
                                             width: cell + 0.4, height: cell + 0.4)),
                                 with: .color(c))
                }
            }
        }
    }
}

// MARK: - 寵物本體

struct PetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bubbleUntil: Date = .distantPast
    @State private var bubbleText: String = ""
    @State private var phraseTick = 0
    /// 點擊泡泡的分頁(0 用量 / 1 寵物 / 2 資料);泡泡顯示中再點會翻頁。
    @State private var bubblePage = 0
    /// 動畫狀態機:one-shot 轉場 + 隨機 micro-animation(引用型別,tick 內推進)。
    @State private var animator = PixelAnimator()

    var body: some View {
        let settings = model.settings
        let mood = model.mood
        let size = settings.petSize
        let paused = settings.quietMode || reduceMotion

        TimelineView(.animation(minimumInterval: 1.0 / 10, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let capD = UsageRingModel.capacityOuterDiameter(petSize: size)

            // R2 B1 兩層巢狀契約:outer = 環容器(容量外徑),inner = sprite+徽章+彩紙
            //(徽章 topTrailing 相對 sprite,不得漂到環外緣)。泡泡改 overlay,
            // 佈局零影響 → 寵物不再因泡泡彈出而位移(R2 B3)。
            GeometryReader { geo in
                ZStack {
                    // 用量環:每家 provider 一圈,identity 色(R2 B2)。
                    UsageRing(limits: model.orderedLimitStates, petSize: size)
                        .frame(width: capD, height: capD)

                    // inner:sprite + mood 徽章 + confetti(既有語彙原封)。
                    ZStack(alignment: .topTrailing) {
                        // E2a:V2 引擎開啟時渲染 driver 發佈的 pack 幀快照(藍鳥真美術);
                        // 快照未達(首 commit 前的極短窗)寧可空白也不閃 legacy 皮。
                        if EngineV2.isEnabled {
                            if let v2 = model.v2Frame {
                                PixelFrameView(rows: v2.rows,
                                               palette: v2.palette,
                                               gridWidth: v2.gridWidth,
                                               gridHeight: v2.gridHeight,
                                               flipped: v2.mirrored)
                                    .frame(width: size * 1.3, height: size * 1.15)
                                    .saturation(mood.mood == .exhausted ? 0.35 : 1)
                                    .opacity(mood.mood == .sleeping ? 0.85 : 1)
                            } else {
                                Color.clear.frame(width: size * 1.3, height: size * 1.15)
                            }
                        } else {
                            // legacy 渲染路徑(V2 關):animator 幀計算只在此分支發生。
                            legacySpriteView(at: context.date, paused: paused, size: size)
                                .saturation(mood.mood == .exhausted ? 0.35 : 1)
                                .opacity(mood.mood == .sleeping ? 0.85 : 1)
                        }

                        if let glyph = PixelGlyphs.glyph(for: mood.mood) {
                            let isAlert = mood.mood == .warning || mood.mood == .exhausted
                            // spec:警戒驚嘆號以整數像素彈跳表現(僅 alert 狀態),
                            // 其餘徽章維持柔和閃爍
                            let bounce: CGFloat = (!paused && isAlert && !Int(t * 2).isMultiple(of: 2)) ? -2 : 0
                            PixelGlyphView(glyph: glyph)
                                .frame(width: size * 0.16, height: size * 0.26)
                                .offset(x: -size * 0.02, y: -size * 0.04 + bounce)
                                .opacity(isAlert || paused ? 1 : 0.55 + 0.45 * abs(sin(t * 3)))
                        }

                        if mood.mood == .celebration {
                            ConfettiPixels(t: paused ? 0 : t)
                                .frame(width: size * 1.3, height: size * 1.15)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: size * 1.3, height: size * 1.15)
                }
                .frame(width: capD, height: capD)
                // R3(grok P1):命中區 = 環容器 —— 上方泡泡保留區是「空氣」,
                // 點到不得觸發泡泡/選單(視窗層仍會擋事件,屬透明浮窗既有代價)。
                .contentShape(Rectangle())
                .onTapGesture {
                    if Date() < bubbleUntil {
                        bubblePage = (bubblePage + 1) % 3
                    } else {
                        bubblePage = 0
                    }
                    showBubble(bubblePageText(bubblePage), seconds: 6)
                }
                .help(PetInfo.tooltip)
                .contextMenu { PetContextMenu() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) {
                    // R3 裁定 A:泡泡完全在環圈之上(底部 = 6 + capD + 8 縫),
                    // 尾巴向下指向寵物;不參與 layout、不吃命中。
                    if context.date < bubbleUntil {
                        PixelBubble(text: bubbleText, maxWidth: geo.size.width - 12)
                            .padding(.bottom, capD + 14)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
            }
        }
        .opacity(settings.petOpacity)
        .onChange(of: model.mood.mood) { _, newMood in
            guard settings.petSpeechEnabled,
                  let phrases = PetSpeech.phrases(for: newMood), !phrases.isEmpty else { return }
            phraseTick += 1
            showBubble(phrases[phraseTick % phrases.count], seconds: 3.5)
        }
        .onChange(of: model.feedNotice?.at) { _, _ in
            if let notice = model.feedNotice {
                showBubble(notice.text, seconds: 4)
            }
        }
        // help/contextMenu/tap 已收斂到環容器(R3 命中區 = capD;保留區點擊不觸發)。
    }

    /// legacy sprite 幀(V2 關的原路徑;抽出以免 V2 開啟時仍逐 tick 計算 animator 幀)。
    private func legacySpriteView(at date: Date, paused: Bool, size: Double) -> some View {
        let settings = model.settings
        let walking = model.wanderDirection != 0
        let state = PixelPets.animState(for: model.mood.mood, walking: walking,
                                        species: settings.resolvedSpecies)
        let sprite = PixelPets.sprite(for: settings.resolvedSpecies)
        let rows = animator.frame(species: settings.resolvedSpecies, target: state, sprite: sprite,
                                  at: date, reduceMotion: paused,
                                  speed: model.mood.animationSpeed)
        return PixelFrameView(rows: rows,
                              palette: sprite.palette,
                              gridWidth: sprite.width,
                              gridHeight: sprite.height,
                              flipped: model.petFacingDirection < 0)
            .frame(width: size * 1.3, height: size * 1.15)
    }

    private func showBubble(_ text: String, seconds: TimeInterval) {
        bubbleText = text
        bubbleUntil = Date().addingTimeInterval(seconds)
    }

    /// 點擊泡泡三頁(spec「Better Pet Click Bubble」的 tap-to-cycle 版本;
    /// 每行壓在 ~26 字內以符合面板寬度):用量 / 寵物 / 資料。
    private func bubblePageText(_ page: Int) -> String {
        switch page {
        case 0:
            let lines = model.orderedLimitStates.prefix(4).map { st -> String in
                let code = shortProviderCode(st.providerId)
                guard let p = st.fiveHour.usedPercent else { return "\(code) — no data" }
                var line = "\(code) \(Int(p.rounded()))% 5h"
                if let reset = st.fiveHour.resetAt { line += " · \(countdown(to: reset))" }
                return line
            }
            return lines.isEmpty ? "no usage data yet" : lines.joined(separator: "\n")
        case 1:
            // R2 B3:縮短最寬行(codex 實算 64pt 面板下 "treats N · burn X/h" 溢出)。
            let pet = model.petState
            return "Lv.\(pet.level) · fullness \(Int(pet.hunger))%\n"
                + "\(model.treatsAvailable) treats · \(tk(Int(model.dashboard.burnRateTokensPerHour)))/h"
        default:
            let refreshed = timeAgo(model.dashboard.lastRefreshAt)
            let flags = model.orderedLimitStates.prefix(4).map { st in
                "\(shortProviderCode(st.providerId)) \(confidenceWord(st.fiveHour.confidence))"
            }
            return (["refreshed \(refreshed)"] + flags).joined(separator: "\n")
        }
    }

    private func confidenceWord(_ confidence: Confidence) -> String {
        switch confidence {
        case .high: return "official"
        case .estimated: return "estimated"
        case .stale: return "stale"
        case .unknown: return "no source"
        }
    }
}

/// 慶祝彩紙:繞頭頂旋轉的 4 顆像素點(程序化,無素材)。
struct ConfettiPixels: View {
    let t: TimeInterval

    var body: some View {
        Canvas { context, size in
            let colors: [Color] = [.yellow, .pink, .teal, .orange]
            for i in 0..<4 {
                let phase = t * 2.2 + Double(i) * .pi / 2
                let x = size.width * 0.5 + cos(phase) * size.width * 0.42
                let y = size.height * 0.28 + sin(phase * 1.4) * size.height * 0.16
                let cell = max(2.5, size.width / 26)
                context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)),
                             with: .color(colors[i]))
            }
        }
    }
}

/// 像素風對話泡泡:階梯圓角、粗黑框、白底、階梯尾巴(8-bit 漫畫風,自繪)。
/// R2 B3:呼叫端傳入可用最大寬(面板實寬 − 12),文字先換行、極端時輕縮 —
/// 任何寵物尺寸下不裁字。
struct PixelBubble: View {
    let text: String
    var maxWidth: CGFloat = .infinity

    private let unit: CGFloat = 3   // 一個「像素」的邊長
    private let border: CGFloat = 3

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.14))
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: maxWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background { bubbleShape }
            .padding(.bottom, unit * 3) // 尾巴空間
    }

    private var bubbleShape: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let u = unit
            let ink = Color(red: 0.1, green: 0.1, blue: 0.12)
            let paper = Color(red: 0.98, green: 0.98, blue: 0.96)
            Canvas { context, _ in
                // 外層(黑框):階梯圓角矩形 = 三個相疊矩形
                func steppedRect(_ rect: CGRect, into path: inout Path) {
                    path.addRect(CGRect(x: rect.minX + u, y: rect.minY, width: rect.width - 2 * u, height: rect.height))
                    path.addRect(CGRect(x: rect.minX, y: rect.minY + u, width: rect.width, height: rect.height - 2 * u))
                }
                var outer = Path()
                steppedRect(CGRect(x: 0, y: 0, width: w, height: h), into: &outer)
                // 尾巴(左下,兩階)
                outer.addRect(CGRect(x: w * 0.28, y: h - u, width: u * 3, height: u * 2))
                outer.addRect(CGRect(x: w * 0.28 - u, y: h + u, width: u * 2, height: u * 2))
                context.fill(outer, with: .color(ink))

                var inner = Path()
                steppedRect(CGRect(x: border, y: border, width: w - 2 * border, height: h - 2 * border), into: &inner)
                inner.addRect(CGRect(x: w * 0.28 + u * 0.5, y: h - u * 2, width: u * 2, height: u * 2))
                context.fill(inner, with: .color(paper))
            }
            .frame(width: w, height: h + u * 3)
        }
    }
}

/// 用量環(R2 B2):**每家有 5h 百分比的 provider 一圈**(同心;Grok nil 跳過),
/// 外→內 = orderedLimitStates 過濾後順序,自 sprite 淨空向外疊(幾何契約見
/// UsageRingModel)。進度弧 = identity 色**恆定**;嚴重度由 mood 徽章承載
///(E2a A11 的環上 warn/danger 換色規則自 R2 廢止 — 僅環,其餘 severity 呈現不動)。
struct UsageRing: View {
    let limits: [ProviderLimitState]
    let petSize: Double

    var body: some View {
        let entries = UsageRingModel.entries(from: limits)
        let usable = 1 - UsageRingModel.gapFraction
        let rotation = Angle.degrees(90 + 360 * UsageRingModel.gapFraction / 2)
        ZStack {
            if entries.isEmpty {
                ring(diameter: UsageRingModel.baseDiameter(petSize: petSize)) {
                    track(usable: usable, rotation: rotation)
                }
            }
            ForEach(Array(entries.enumerated()), id: \.element.providerId) { k, entry in
                let d = UsageRingModel.diameter(index: k, count: entries.count, petSize: petSize)
                ring(diameter: d) {
                    ZStack {
                        track(usable: usable, rotation: rotation)
                        Circle()
                            .trim(from: 0, to: usable * min(1, max(0.01, entry.percent / 100)))
                            .stroke(identityColor(entry.providerId),
                                    style: StrokeStyle(lineWidth: UsageRingModel.strokeWidth, lineCap: .round))
                            .rotationEffect(rotation)
                    }
                }
            }
        }
        .help(helpText(entries))
        .accessibilityLabel(helpText(entries))
        .allowsHitTesting(false)
    }

    /// stroke 置中於路徑 → frame 內縮一個線寬,外緣恰為 diameter(不外溢容器)。
    private func ring<Content: View>(diameter: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: diameter - UsageRingModel.strokeWidth,
                   height: diameter - UsageRingModel.strokeWidth)
    }

    private func track(usable: Double, rotation: Angle) -> some View {
        Circle()
            .trim(from: 0, to: usable)
            .stroke(Theme.textDisabled.opacity(0.22),
                    style: StrokeStyle(lineWidth: UsageRingModel.strokeWidth, lineCap: .round))
            .rotationEffect(rotation)
    }

    private func identityColor(_ providerId: String) -> Color {
        let brand = ProviderBrands.brand(for: providerId)
        return Color(red: Double((brand.dotColor >> 16) & 0xFF) / 255,
                     green: Double((brand.dotColor >> 8) & 0xFF) / 255,
                     blue: Double(brand.dotColor & 0xFF) / 255)
    }

    private func helpText(_ entries: [UsageRingModel.Entry]) -> String {
        guard !entries.isEmpty else { return "No 5h limit data" }
        return entries.map { e in
            "\(ProviderBrands.brand(for: e.providerId).displayName) \(Int(e.percent.rounded()))%"
        }.joined(separator: " · ") + " (5h)"
    }
}

struct GaugeBar: View {
    let percent: Double
    let warn: Double
    /// 紅色門檻:與 severity 上色一致改用 danger 閾值(預設維持既有 99.5 相容)。
    var danger: Double = 99.5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if percent > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, geo.size.width * min(1, percent / 100)))
                }
            }
        }
    }

    private var color: Color {
        if percent >= danger { return .red }
        if percent >= warn { return .orange }
        return .green
    }
}

struct PetContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("Give Treat (\(model.treatsAvailable))") {
            ForEach(FoodItem.foods(for: model.settings.resolvedSpecies)) { food in
                Button("\(food.emoji) \(food.name)\(food.treatCost > 0 ? "  — \(food.treatCost)🎟" : "")") {
                    _ = model.feed(food)
                }
            }
        }
        Divider()
        Button("Open Dashboard") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "dashboard")
        }
        Button(model.settings.petWanderEnabled ? "Pet Movement: On" : "Pet Movement: Off") {
            model.updateSettings { $0.petWanderEnabled.toggle() }
        }
        Button(model.settings.quietMode ? "Quiet Mode: On" : "Quiet Mode: Off") {
            model.updateSettings { $0.quietMode.toggle() }
        }
        Button("Hide Pet") {
            model.updateSettings { $0.petVisible = false }
        }
    }
}
