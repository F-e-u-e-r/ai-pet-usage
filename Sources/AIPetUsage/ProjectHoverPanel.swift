import SwiftUI
import AppKit
import UsageCore

// Usage-M3 A1 — presentation + tracking architecture (owner re-architecture 2026-09-24, spike #2 FAILED).
// Replaces BOTH the in-window SwiftUI `.overlay` preview (clipped to the dashboard window) and the SwiftUI
// `.onContinuousHover` + `.id(hoverEpoch)` re-arm (failed tab re-entry) with:
//   • ONE persistent, non-activating, OUTPUT-ONLY `NSPanel` positioned in SCREEN coords (may extend beyond the
//     dashboard window; clamped only to `NSScreen.visibleFrame`).
//   • ONE stable `NSTrackingArea` pointer source over the Projects viewport (survives SwiftUI/TabView lifecycle).
// The ROW-ONLY contract is preserved: local point → row resolver → FSM; screen point → panel position. The
// panel NEVER feeds hover resolution. STILL FORBIDDEN (owner): HoverZone.card, CardFrameKey/cardFrames,
// lastPointer reconstruction, generation/version token, per-view hover callbacks, a 2nd pointer source,
// SwiftUI `.popover`. The pure pieces (`HoverZoneResolver`, `AnchoredHoverModel`, `PanelPlacement`) live in
// UsageCore and are unit-tested; this file is the AppKit glue (runtime-verified in the owner spike).


/// Output-only auxiliary panel. `canBecomeKey/Main == false` guarantees it never steals focus/activation
/// (owner requirement); `ignoresMouseEvents` keeps it out of hit-testing entirely.
final class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Presentation shell for the hover panel (owner spike#3 fix #1): the `HoverPanel` is transparent, so the
/// preview needs its own material card background + rounded shape here. Kept OUT of the reusable
/// `ModelDrilldownPopover` so that content stays presentation-shell-agnostic. Shadow is owned by the NSPanel.
private struct ProjectHoverPanelContent: View {
    let projectName: String
    let rows: [ModelUsageSummary]

    var body: some View {
        ModelDrilldownPopover(projectName: projectName, rows: rows)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// The single NSTrackingArea pointer source over the Projects ScrollView viewport. `isFlipped` gives it a
/// top-left origin so its local coordinates match the SwiftUI `RowFramesKey` rects (same viewport space).
/// `hitTest` returns nil so the view is transparent to clicks (rows keep click-focus); the tracking area still
/// delivers `mouseMoved`/`mouseExited` to this owner despite that — confirmed by the owner spike #3 runtime
/// (the tracker fired throughout with `hitTest`→nil).
final class HoverTrackingNSView: NSView {
    var onMoved: ((CGPoint, CGPoint) -> Void)?   // (viewport-local point, screen point)
    var onExited: (() -> Void)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // transparent to clicks

    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // owner spike#3 hardening: remove ONLY our own area (never `trackingAreas` wholesale) and reinstall for
        // the current (possibly resized) bounds. `.inVisibleRect` keeps the area == visible bounds under scroll/clip.
        if let existing = hoverTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true   // required for mouseMoved delivery
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)   // flipped → top-left, matches rowFrames
        onMoved?(local, NSEvent.mouseLocation)                   // NSEvent.mouseLocation = screen coords
    }
    // owner D4 — best-effort hardening for a STATIONARY-pointer re-entry (tab/key return with the cursor already
    // over a row): forward `mouseEntered` down the SAME resolve path as `mouseMoved`, so the row can resolve
    // without an extra physical move. NOT a guarantee — AppKit does not always synthesize `mouseEntered` when the
    // pointer is already inside on re-arm; if an activation skips it, the next real move recovers (accepted RECORD,
    // no mechanism expansion: no synthetic polling / 2nd pointer source / stored-pointer reconstruction).
    override func mouseEntered(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        onMoved?(local, NSEvent.mouseLocation)
    }
    override func mouseExited(with event: NSEvent) { onExited?() }
}

/// SwiftUI bridge for the single tracking source. Placed as an overlay of the Projects ScrollView.
struct HoverTrackingRepresentable: NSViewRepresentable {
    let controller: ProjectHoverController

    func makeNSView(context: Context) -> HoverTrackingNSView {
        let view = HoverTrackingNSView()
        view.onMoved = { [controller] local, screen in controller.pointerMoved(local: local, screen: screen) }
        view.onExited = { [controller] in controller.pointerExited() }
        return view
    }
    func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {}
}

/// Owns the hover FSM + the single presentation panel + row geometry + drill-down data + the grace timer.
/// Fed by the tracker (pointer), SwiftUI (`RowFramesKey`, `@FocusState`, Esc, `isActive`, `controlActiveState`,
/// disappear) and the grace timer. `shownKey` (from the pure FSM) decides show/hide; `PanelPlacement` (pure)
/// decides where. `@Published isShowing` lets the view gate the window-level Esc catcher. @MainActor: touches
/// AppKit and is called only from the main thread.
@MainActor
final class ProjectHoverController: ObservableObject {
    @Published private(set) var isShowing = false

    private var model = AnchoredHoverModel()          // the pure row-only FSM (UsageCore, unit-tested)
    private var rowRects: [String: CGRect] = [:]      // visible rows, viewport space (from RowFramesKey)
    private var projectModels: [String: [ModelUsageSummary]] = [:]
    private var names: [String: String] = [:]         // projectId → displayName (drill-down title)
    private var isActive = false                       // Projects is the current tab
    private var windowIsKey = true

    private var panel: HoverPanel?
    private var hosting: NSHostingView<ProjectHoverPanelContent>?
    private var dismissTask: Task<Void, Never>?
    private let dismissGrace: TimeInterval = 0.18       // spike-tunable; NOT a contract value
    // spike#3 fix #1 hot-path cache: the CONTENT path (rebuild rootView + layout + fittingSize) runs only when the
    // shown key or the page data changes; ordinary mouseMoved takes the POSITION path (move the existing panel with
    // this cached size — no rootView swap / no layout / no fittingSize). Kills the per-move "一卡一卡".
    private var presentedKey: String?
    private var panelSize: CGSize = .zero

    // MARK: inputs from SwiftUI

    func setData(projectModels: [String: [ModelUsageSummary]], names: [String: String]) {
        self.projectModels = projectModels
        self.names = names
        // owner D2 — a data change NEVER creates presentation ownership. Reconcile on the NEXT runloop (keeps any
        // @Published `isShowing` flip OUT of ProjectTable's view update), but only to refresh an already-VISIBLE
        // eligible panel in place, or hide it if its slice became ineligible. A hidden panel STAYS hidden — a
        // static-cursor empty→refill no longer auto-resurrects it (accepted RECORD); the next genuine pointer/
        // focus input opens it normally. Not visible → nothing to do.
        guard isShowing else { return }
        DispatchQueue.main.async { [weak self] in self?.reconcileAfterDataChange() }
    }

    /// Deferred data-change reconcile (never runs inside a SwiftUI update). owner D2: refresh IN PLACE or hide —
    /// never (re)position from the raw cursor, never autonomously open a hidden panel. Ineligible (shown key
    /// empty/missing, not active, or non-key) → hide; visible + eligible → rebuild content + re-measure while
    /// PRESERVING the current placement; hidden → do nothing (the static-cursor empty→refill non-resurrect RECORD).
    private func reconcileAfterDataChange() {
        // owner sol#1 fix: when the shown key's slice becomes ineligible (empty/missing/inactive/non-key) the panel
        // hides AND the FSM's ownership of that key is dropped (`forceDismiss`). Without the drop, `shownKey` stays
        // set while hidden, so a later GEOMETRY render (`setRows` → `renderNow`, e.g. from a scroll/layout
        // `onPreferenceChange`) would re-show the panel with NO pointer/focus input — breaking the D2 hidden→refill
        // RECORD. After the drop, a fresh pointer move / focus event reopens it normally. (Design RECORD: a
        // statically focus-held row that empties→refills stays hidden until the next real input — RECORD-consistent.)
        guard isActive, windowIsKey, let key = model.shownKey, !(projectModels[key] ?? []).isEmpty else {
            model.forceDismiss(); hide(); return
        }
        guard isShowing, let panel else { return }   // hidden → never autonomously (re)open
        refreshContentInPlace(key: key, panel: panel)
    }

    func setRows(_ rects: [String: CGRect]) {
        // owner D3-completion: the controller accepts LIVE resolver geometry ONLY while active. A late non-empty
        // `RowFramesKey` callback during inactive tab teardown must NOT re-arm `rowRects` after `setActive(false)`
        // cleared it — otherwise an inactive-period identity change would leave stale rects that resolve the first
        // pointer event to the WRONG project. Guarded controller-side (not View-side) so the ownership invariant —
        // `rowRects` is live geometry, accepted only while active — holds for ANY caller. The View may keep updating
        // its retained `@State rowFrames` while inactive; re-activation hands it back under an identity match.
        guard isActive else { return }
        guard rects != rowRects else { return }
        rowRects = rects
        // Layout/scroll moved the rows under a possibly-static cursor → the FSM's pointer zone is stale. Invalidate
        // pointer ownership and let the grace close it (focus, if any, still holds). No lastPointer re-resolution
        // (STOP contract) — same accepted RECORD as the SwiftUI version.
        model.pointerMoved(to: .none)
        if model.shownKey != nil || !model.isIdle { ensureDismissScheduled() }
        renderNow(mouse: NSEvent.mouseLocation)   // geometry = .syncOnly (default): reposition/switch/hide a visible panel, never OPEN a hidden one
    }

    /// A row left the tree (LazyVStack scroll recycle). Synchronously drop its stale rect — so a static cursor
    /// can't re-resolve the recycled row before the next preference flush — and reconcile the FSM (revert to a
    /// still-focused sibling, or dismiss). Preserves the row-recycle contract from the SwiftUI version.
    func rowDisappeared(_ key: String) {
        rowRects.removeValue(forKey: key)
        model.rowDisappeared(key)
        renderNow(mouse: NSEvent.mouseLocation)   // geometry = .syncOnly (default): never OPEN a hidden panel
    }

    func setFocus(old: String?, new: String?) {
        // owner mechanism correction: only a focus GAIN on a row right now is a positive user anchor that may open a
        // hidden panel; a focus LOSS/blur is `.syncOnly` (must not open).
        let gainedFocus = new != nil && isActive && windowIsKey
        if let old { model.blur(row: old) }
        if let new, isActive, windowIsKey { cancelDismiss(); model.focus(row: new) }
        else { scheduleDismiss() }
        renderNow(mouse: NSEvent.mouseLocation, intent: gainedFocus ? .userOpen : .syncOnly)
    }

    func escape() { model.escape(); scheduleDismiss(); renderNow(mouse: NSEvent.mouseLocation) }

    /// Projects became / stopped being the current tab. Activate = fresh session (no data reload, no `.id`
    /// recreation — the tracker re-arms itself). Deactivate = DROP LIVE ROW GEOMETRY (owner D3-completion) + hard
    /// clear. `rowRects` is LIVE geometry and must NOT survive deactivation: if the page/order identity changes
    /// while Projects is inactive, the View correctly withholds the re-hand (`RowGeometryIdentity` mismatch) — but a
    /// surviving stale `rowRects` would still let the first `mouseEntered`/`mouseMoved` resolve to the WRONG project
    /// before a fresh `RowFramesKey` lands. Retained geometry lives ONLY in the View's `@State rowFrames`, re-handed
    /// on return solely when its identity still matches (empty `rowRects` ⇒ resolver returns `.none` ⇒ temporary
    /// no-hover > wrong-project). NOT cleared in `hardClear`: `setWindowActive(false)` (lost key window) keeps the
    /// still-valid geometry, so the clear is scoped to tab-deactivation here.
    func setActive(_ active: Bool) {
        isActive = active
        if active { model = AnchoredHoverModel() } else { rowRects = [:]; hardClear() }
    }

    func setWindowActive(_ isKey: Bool) {
        windowIsKey = isKey
        if !isKey { hardClear() }   // lost key window → hide (owner: non-key must not show)
    }

    func teardown() { hardClear() }   // onDisappear

    // MARK: input from the tracker

    func pointerMoved(local: CGPoint, screen: CGPoint) {
        guard isActive, windowIsKey else { return }   // owner D5: fail-closed — never resolve/present in a non-key window
        let zone = HoverZoneResolver.zone(at: local, rowRects: rowRects)
        // owner spike#3 MUST-FIX (leaving a row's bounds must hide): EDGE-trigger the grace while the pointer is off
        // all rows — continuous movement through blank space must NOT keep rescheduling (that is why a stale panel
        // lingered/followed and never hid). Schedule once (only if a panel is shown); a real re-entry onto a row
        // cancels it (so an A→brief-gap→B seam still bridges). NOT changing resolver/FSM (resolver already returns
        // `.none` off-rows — this spike's trace confirmed Case A, a controller-transition bug, not a hit-test one).
        if zone == .none {
            // owner D1 (sol#1): restore `|| !model.isIdle` — a focus-held fallback (shown key suppressed while a
            // row stays focused) must still schedule the commit that reconciles the preview back to it.
            if model.shownKey != nil || !model.isIdle { ensureDismissScheduled() }
        } else {
            cancelDismiss()
        }
        model.pointerMoved(to: zone)
        // Follow the cursor ONLY while the pointer is on the shown row — never during the grace over blank / another
        // row (following there is what let the stale panel drift into empty space).
        let follow: Bool = { if case .row(let k) = zone, k == model.shownKey { return true } else { return false } }()
        // owner mechanism correction: opening a HIDDEN panel is allowed here ONLY when the pointer resolves to a row
        // NOW (`.userOpen`); pointer → `.none`/blank is `.syncOnly` — e.g. leaving a no-usage row that still lingers as
        // `shownKey` must NOT open the panel on the way into blank.
        let intent: HoverPresentationIntent = { if case .row = zone { return .userOpen } else { return .syncOnly } }()
        renderNow(mouse: screen, follow: follow, intent: intent)
    }

    func pointerExited() {
        guard isActive else { return }
        model.pointerMoved(to: .none)
        scheduleDismiss()
    }

    // MARK: grace timer (single cancellable dismiss; edge-triggered re-schedule for layout churn)

    // owner D6 — cancellation-aware grace primitive (single cancellable Task). Contract: once a dismiss is
    // cancelled by a genuine re-entry, that cancelled operation must NEVER later call `commitDismiss()`. The
    // explicit `Task.isCancelled` guard proves that at the resume point (the prior DispatchWorkItem left it
    // implicit in dispatch cancellation semantics). NOT a generation/version token, NO FSM redesign, NO 2nd
    // pointer source — only the scheduling primitive. `@MainActor` keeps every state touch on the main thread.
    private func scheduleDismiss() {
        dismissTask?.cancel()
        let grace = dismissGrace
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.model.commitDismiss()
            self.dismissTask = nil
            // grace timer = .syncOnly (default): reconciles a VISIBLE panel (keep-on-focus / switch / hide) but NEVER
            // opens a HIDDEN one — this is the luna/sol-r4 fix (a geometry-scheduled grace can no longer re-open).
            self.renderNow(mouse: NSEvent.mouseLocation)
        }
    }
    private func cancelDismiss() { dismissTask?.cancel(); dismissTask = nil }
    private func ensureDismissScheduled() { if dismissTask == nil { scheduleDismiss() } }

    // MARK: panel

    private func hardClear() {
        cancelDismiss()
        model.forceDismiss()
        hide()
    }

    /// Reconcile the panel to the FSM's `shownKey`. `mouse` positions it (live cursor point — never a
    /// reconstructed/stored pointer used for resolution).
    private func renderNow(mouse: CGPoint, follow: Bool = false, intent: HoverPresentationIntent = .syncOnly) {
        // owner spike#3 MUST-FIX:沒有 model usage 的 project **不是 hover target** —— 空(或缺)切片絕不 present
        // panel(也不顯示「No model usage…」)。此 guard 使 has-usage→no-usage 立即 hide、blank→no-usage 不 flash;
        // 只有真正有 usage 的 row 進 content path。不動 resolver/FSM(row 仍可被解析,只是 presentation 不呈現)。
        guard isActive, windowIsKey, let key = model.shownKey, !(projectModels[key] ?? []).isEmpty else { hide(); return }
        // owner mechanism correction 2026-09-25 — OPENING authority is by EVENT SEMANTIC + default-CLOSED (see
        // `PresentationGate`). A HIDDEN panel opens ONLY on `.userOpen` (pointer→row / focus-gain NOW); every other
        // trigger — geometry, the grace Task, data, Esc, blur, pointer→`.none` — is `.syncOnly` and may only
        // reposition/switch/hide an ALREADY-visible panel. `intent` defaults to `.syncOnly`, so a future caller that
        // forgets to classify fails CLOSED (cannot open a hidden panel). This replaces the `mayOpen` boolean whose
        // per-caller opt-out was routed around by the deferred grace (luna/sol-r4).
        switch PresentationGate.action(isShowing: isShowing, keyIsPresented: key == presentedKey, intent: intent, follow: follow) {
        case .reposition: reposition(mouse: mouse)   // POSITION path (hot): move only when the pointer is ON the shown row
        case .present:    showContent(key: key, mouse: mouse)   // CONTENT path: (re)build + measure + show / SWITCH
        case .ignore:     break
        }
    }

    /// CONTENT path — runs on first show / A→B switch / data change only: rebuild rootView, layout once, measure
    /// once, cache the presented key + size, then place & show. NEVER runs on ordinary movement.
    private func showContent(key: String, mouse: CGPoint) {
        let content = ProjectHoverPanelContent(projectName: names[key] ?? "", rows: projectModels[key] ?? [])
        let host: NSHostingView<ProjectHoverPanelContent>
        if let existing = hosting { existing.rootView = content; host = existing }
        else { host = NSHostingView(rootView: content); hosting = host }
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        if size.width < 1 || size.height < 1 { size = CGSize(width: 760, height: 240) }   // pre-layout fallback
        presentedKey = key
        panelSize = size

        let panel = ensurePanel(host: host)
        let frame = PanelPlacement.frame(mouse: mouse, panelSize: size, screen: screenFrame(containing: mouse))
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
        if !isShowing { isShowing = true }
    }

    /// owner D2 — refresh a VISIBLE panel's content in place: rebuild rootView + re-measure, but PRESERVE the
    /// current placement (never re-anchor to the raw cursor). Resize + clamp within the panel's current screen
    /// only if the fitting size changed; otherwise leave the frame untouched. Never opens a hidden panel.
    private func refreshContentInPlace(key: String, panel: HoverPanel) {
        let content = ProjectHoverPanelContent(projectName: names[key] ?? "", rows: projectModels[key] ?? [])
        let host: NSHostingView<ProjectHoverPanelContent>
        if let existing = hosting { existing.rootView = content; host = existing }
        else { host = NSHostingView(rootView: content); hosting = host }
        host.layoutSubtreeIfNeeded()
        var size = host.fittingSize
        if size.width < 1 || size.height < 1 { size = panelSize }   // keep last good size on a bad measure
        presentedKey = key
        guard size != panelSize else { return }                     // unchanged size → keep the frame as-is
        panelSize = size
        // owner D2 / sol#2 fix: preserve the current origin but CAP the size to the screen + clamp fully inside via
        // PanelPlacement.reframe — never re-anchor to the cursor, and never let an oversized preview (natural width >
        // screen) overflow the visible frame (the earlier inline path clamped only the origin, leaving the panel
        // wider than the screen and partly off it).
        let origin = panel.frame.origin
        panel.setFrame(PanelPlacement.reframe(origin: origin, naturalSize: size, screen: screenFrame(containing: origin)),
                       display: true)
    }

    /// POSITION path (the hot path — ordinary mouseMoved within the SAME shown row): move the existing panel with
    /// the CACHED size. No rootView swap, no layoutSubtreeIfNeeded, no fittingSize. Prefer `setFrameOrigin` (no
    /// redraw) when size is unchanged; fall back to `setFrame` only if the placement had to clamp the size.
    private func reposition(mouse: CGPoint) {
        guard let panel else { return }
        let frame = PanelPlacement.frame(mouse: mouse, panelSize: panelSize, screen: screenFrame(containing: mouse))
        if frame.size == panelSize { panel.setFrameOrigin(frame.origin) }
        else { panel.setFrame(frame, display: false) }
    }

    private func hide() {
        panel?.orderOut(nil)
        presentedKey = nil                       // next show rebuilds content (CONTENT path)
        if isShowing { isShowing = false }
    }

    private func ensurePanel(host: NSView) -> HoverPanel {
        if let panel {
            if panel.contentView !== host { panel.contentView = host }
            return panel
        }
        let p = HoverPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 240),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true                     // output-only; never a hover/input owner
        p.hidesOnDeactivate = false                     // visibility managed explicitly
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.animationBehavior = .none
        p.contentView = host
        panel = p
        return p
    }

    private func screenFrame(containing point: CGPoint) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
