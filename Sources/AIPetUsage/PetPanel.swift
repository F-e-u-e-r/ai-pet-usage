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
    /// 手動拖曳的位置持久化去抖:每個 windowDidMove 取消上一個,拖曳靜止後才寫一次 settings.json。
    private var positionSaveTask: Task<Void, Never>?
    /// 漫遊位移期間為 true,windowDidMove 據此略過位置持久化(避免每秒十餘次寫檔)。
    private var isWanderMoving = false
    private var wanderHeading: Int = 1
    private var wanderPhaseUntil: Date = .distantPast

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

    private func panelSize() -> NSSize {
        let base = model?.settings.petSize ?? 96
        return NSSize(width: base * 2.2, height: base * 2.0)
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
        restartWanderLoop()
    }

    func hide() {
        panel?.orderOut(nil)
        stopWanderLoop()
    }

    func destroy() {
        stopWanderLoop()
        // 拖曳去抖尚未落地就 teardown(例如切到 monitor-only)會遺失最後位置,先補寫一次再取消。
        if positionSaveTask != nil, let panel, !isWanderMoving {
            model?.savePetPosition(panel.frame.origin)
        }
        positionSaveTask?.cancel()
        positionSaveTask = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
    }

    func apply(settings: AppSettings) {
        guard let panel else {
            if settings.petVisible { show() }
            return
        }
        panel.ignoresMouseEvents = settings.clickThrough
        let newSize = panelSize()
        if abs(panel.frame.width - newSize.width) > 1 {
            var frame = panel.frame
            frame.size = newSize
            panel.setFrame(frame, display: true)
            panel.contentView?.frame = NSRect(origin: .zero, size: newSize)
        }
        if settings.petVisible { show() } else { hide() }
        restartWanderLoop()
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            guard let panel = self.panel, !self.isWanderMoving else { return }
            // 去抖:拖曳期間每個 move 事件取消上一個排程,靜止 0.4s 後才寫一次 settings.json。
            let origin = panel.frame.origin
            self.positionSaveTask?.cancel()
            self.positionSaveTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                self?.model?.savePetPosition(origin)
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
        guard model?.settings.petWanderEnabled == true else { return }
        wanderTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 90_000_000) // ~11 Hz,CPU 影響可忽略
                await self?.wanderTick()
            }
        }
    }

    private func wanderTick() {
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
        let minX = screen.minX + 12
        let maxX = screen.maxX - panel.frame.width - 12
        if origin.x <= minX || origin.x >= maxX {
            wanderHeading *= -1
            model.setWanderDirection(wanderHeading)
            origin.x = min(max(origin.x, minX), maxX)
        }
        isWanderMoving = true
        panel.setFrameOrigin(origin)
        isWanderMoving = false
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
            let walking = model.wanderDirection != 0
            let state = PixelPets.animState(for: mood.mood, walking: walking, species: settings.species)
            let sprite = PixelPets.sprite(for: settings.species)
            let rows = animator.frame(species: settings.species, target: state, sprite: sprite,
                                      at: context.date, reduceMotion: paused,
                                      speed: mood.animationSpeed)

            VStack(spacing: 2) {
                if context.date < bubbleUntil {
                    PixelBubble(text: bubbleText)
                        .transition(.opacity)
                }
                ZStack(alignment: .topTrailing) {
                    PixelFrameView(rows: rows,
                                   palette: sprite.palette,
                                   gridWidth: sprite.width,
                                   gridHeight: sprite.height,
                                   flipped: model.wanderDirection < 0)
                        .frame(width: size * 1.3, height: size * 1.15)
                        .saturation(mood.mood == .exhausted ? 0.35 : 1)
                        .opacity(mood.mood == .sleeping ? 0.85 : 1)

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

                // 每家 provider 各一條迷你量表:識別 dot + 代號 + severity 上色量表
                VStack(spacing: 2) {
                    ForEach(model.orderedLimitStates.prefix(4)) { limit in
                        let brand = ProviderBrands.brand(for: limit.providerId)
                        HStack(spacing: 4) {
                            ProviderDot(brand: brand, size: 5)
                            Text(brand.code)
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 16, alignment: .trailing)
                            GaugeBar(percent: limit.fiveHour.usedPercent ?? 0,
                                     warn: settings.core.warnThresholdPercent,
                                     danger: settings.core.dangerThresholdPercent)
                                .frame(height: 3)
                                .opacity(limit.fiveHour.usedPercent == nil ? 0.25 : 0.9)
                        }
                        .help("\(brand.displayName) — 5h window usage")
                    }
                }
                .frame(width: size * 1.0)
            }
            .padding(6)
        }
        .opacity(settings.petOpacity)
        .contentShape(Rectangle())
        .onTapGesture {
            if Date() < bubbleUntil {
                bubblePage = (bubblePage + 1) % 3
            } else {
                bubblePage = 0
            }
            showBubble(bubblePageText(bubblePage), seconds: 6)
        }
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
        .help(PetInfo.tooltip)
        .contextMenu { PetContextMenu() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
            let pet = model.petState
            return "Lv.\(pet.level) · fullness \(Int(pet.hunger))%\n"
                + "treats \(model.treatsAvailable) · burn \(tk(Int(model.dashboard.burnRateTokensPerHour)))/h"
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
struct PixelBubble: View {
    let text: String

    private let unit: CGFloat = 3   // 一個「像素」的邊長
    private let border: CGFloat = 3

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.14))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
            ForEach(FoodItem.foods(for: model.settings.species)) { food in
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
        Button(model.settings.petWanderEnabled ? "Wandering: On" : "Wandering: Off") {
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
