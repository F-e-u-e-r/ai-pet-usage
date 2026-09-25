import Foundation
import CoreGraphics

/// Usage-M3 A1 — the project ROW-ONLY hover/focus preview interaction (owner replacement contract
/// 2026-09-24). The card-zone architecture is DELETED: there is no `HoverZone.card`, no card geometry in
/// resolution, no `CardFrameKey`/`cardFrames`, no `lastPointer`, no geometry→FSM re-resolution, no
/// presentation versioning. Hover resolution is purely "which ROW contains the pointer?". The preview is
/// visual-only (`allowsHitTesting(false)`) and NEVER participates in resolution — moving onto it resolves
/// the row beneath (switch) or none (grace dismiss); focus and the grace window keep it usable.
///
/// Three pure, SwiftUI-free pieces, all unit-tested:
///   • `HoverZoneResolver` — pointer location + visible row rects → the current `HoverZone` (row / none).
///   • `AnchoredHoverModel` — the state machine. The view feeds it ONE always-current `pointerMoved(to:)`
///     (plus keyboard focus, Esc, a grace `commitDismiss`, and hard clears); it derives `shownKey`.
///   • `PanelPlacement` — the presentation panel's SCREEN frame from the cursor point + panel size + the
///     usable screen (lower-right of the cursor, flip/clamp to the screen). Display-only geometry; it is
///     NEVER read back into hover resolution (STOP contract).
///
/// Because the pointer zone is always current and rows do not overlap, there are no stale callbacks and no
/// card lifecycle to defend against. Esc-suppression retirement is synchronous — a suppressed key releases
/// the moment the pointer (and focus) leave its row, observed on the next `pointerMoved`/`blur`.
///
/// Invariants: resolution uses ONLY the pointer location + in-memory row geometry; the preview reads the
/// already-built `projectModels[key]` slice (0 ledger walks, 0 coordinator/projectPage lookups).

public enum HoverZone: Equatable, Sendable {
    case row(String)    // pointer is over this project row
    case none           // pointer is over no row
}

public enum HoverZoneResolver {
    /// Resolve the pointer's zone from row geometry alone. Rows do not overlap → at most one contains the
    /// point. Pure: no view, coordinator, ledger, or card-geometry dependency.
    /// - point:    pointer location in the table's coordinate space.
    /// - rowRects: visible rows' frames keyed by project id.
    public static func zone(at point: CGPoint, rowRects: [String: CGRect]) -> HoverZone {
        // Deterministic despite dict order: non-overlapping rows mean at most one match.
        for (id, rect) in rowRects where rect.contains(point) { return .row(id) }
        return .none
    }
}

public struct AnchoredHoverModel: Equatable, Sendable {
    /// The row whose preview should be presented (nil = none). The view's sole output binding.
    public private(set) var shownKey: String?

    private var zone: HoverZone = .none      // the pointer's CURRENT zone (always up to date from the source)
    private var focusedRow: String?          // keyboard focus (independent of pointer tracking)
    private var suppressed: Set<String> = [] // Esc-dismissed keys; each retires once its row + focus clear

    public init() {}

    /// The project the pointer currently implicates (a row), else nil.
    private var pointerKey: String? {
        switch zone {
        case .row(let k): return k
        case .none: return nil
        }
    }

    /// Nothing holds the preview open: pointer over no row, and no focused row.
    public var isIdle: Bool { zone == .none && focusedRow == nil }

    /// The single anchor that should own the preview: the pointer's key wins, else the focused row.
    private var activeCandidate: String? { pointerKey ?? focusedRow }

    private mutating func reconcile() {
        if let c = activeCandidate, !suppressed.contains(c) { shownKey = c } else { shownKey = nil }
    }

    /// Retire Esc-suppression for any key no longer held by the pointer zone or focus. Synchronous — runs
    /// on every pointer/focus change, so "suppress until the pointer leaves that key's row" is exact.
    private mutating func retireUnoccupied() {
        guard !suppressed.isEmpty else { return }
        suppressed = suppressed.filter { $0 == pointerKey || $0 == focusedRow }
    }

    /// The single always-current pointer update from the continuous-hover source. A show target (row)
    /// resolves immediately; `.none` defers dismissal to the grace-debounced `commitDismiss` (so a brief
    /// gap between rows doesn't flicker).
    public mutating func pointerMoved(to zone: HoverZone) {
        self.zone = zone
        retireUnoccupied()
        if zone != .none { reconcile() }
    }

    public mutating func focus(row key: String) { focusedRow = key; retireUnoccupied(); reconcile() }
    public mutating func blur(row key: String) { if focusedRow == key { focusedRow = nil }; retireUnoccupied() }

    /// Esc, identity-scoped: only the row actually showing may be dismissed. Suppress its reopen; the
    /// suppression retires when the pointer (and focus) next leave its row (`retireUnoccupied`).
    public mutating func escape(row key: String) {
        guard shownKey == key else { return }
        suppressed.insert(key)
        shownKey = nil
        // rowonly-r1 sol finding 3: if the row was shown-in-grace but ALREADY unoccupied (pointer left to
        // .none before Esc), a suppression here would strand — retire it at once so a fresh hover reopens.
        retireUnoccupied()
    }
    /// Convenience for the window-level Esc catcher — acts on whatever is live.
    public mutating func escape() { if let k = shownKey { escape(row: k) } }

    /// Grace timer fired (pointer sat at `.none` past the grace): dismiss unless focus still holds it.
    public mutating func commitDismiss() { retireUnoccupied(); reconcile() }

    /// Hard clear for environment loss (Projects tab hidden / window no longer key).
    public mutating func forceDismiss() {
        shownKey = nil
        zone = .none
        focusedRow = nil
        suppressed.removeAll()
    }

    /// A row left the view tree (LazyVStack scroll-away / recycle). If it owned the pointer zone or focus,
    /// drop it, then reconcile (revert to a still-focused sibling, or dismiss).
    public mutating func rowDisappeared(_ key: String) {
        // rowonly-r1 sol finding 4: only reconcile when the vanished row was actually implicated (owned the
        // pointer/focus, or was the one shown). An UNRELATED row's recycle must NOT reconcile — that would
        // clear a preview held in the grace window (zone .none, no candidate) and short-circuit its grace.
        let wasRelevant = pointerKey == key || focusedRow == key || shownKey == key
        if pointerKey == key { zone = .none }
        if focusedRow == key { focusedRow = nil }
        suppressed.remove(key)
        if wasRelevant { reconcile() }
    }
}

/// Usage-M3 A1 — pure SCREEN placement for the presentation panel (owner re-architecture 2026-09-24). The
/// in-window `.overlay` preview is ABANDONED: the preview now lives in a persistent, non-activating auxiliary
/// panel (an `NSPanel`) positioned in SCREEN coordinates, so it MAY extend beyond the dashboard window (but
/// never beyond the usable screen). This is the pure geometry — SwiftUI/AppKit-free, unit-tested — and, like
/// the resolver, it feeds ONLY the display: panel geometry is NEVER read back into hover resolution (STOP).
///
/// Coordinates are AppKit screen space (origin BOTTOM-left, y increases UPWARD) to match `NSScreen.visibleFrame`
/// and `NSEvent.mouseLocation`. Default placement is the cursor's lower-right with a small gap; flip LEFT if it
/// would overflow the right edge, flip ABOVE if it would overflow the bottom, then clamp fully inside `screen`.
public enum PanelPlacement {
    /// - mouse:     cursor location in screen coords.
    /// - panelSize: the panel's fitting size.
    /// - screen:    the usable screen rect (`NSScreen.visibleFrame`) — the ONLY clamping boundary. The dashboard
    ///              window is deliberately NOT a boundary here; the panel is allowed to exceed it.
    /// - gap:       spacing between cursor and panel (owner: 12–16pt; default 14).
    public static func frame(mouse: CGPoint, panelSize: CGSize, screen: CGRect, gap: CGFloat = 14) -> CGRect {
        let w = min(panelSize.width, screen.width)
        let h = min(panelSize.height, screen.height)

        // Horizontal: prefer to the RIGHT of the cursor; flip LEFT if the right edge would overflow the screen.
        var x = mouse.x + gap
        if x + w > screen.maxX { x = mouse.x - gap - w }

        // Vertical (y-up): prefer BELOW the cursor — panel top just under the cursor → origin = mouse.y − gap − h;
        // flip ABOVE (origin = mouse.y + gap) if the below placement would overflow the bottom edge.
        var y = mouse.y - gap - h
        if y < screen.minY { y = mouse.y + gap }

        // Clamp fully inside the usable screen (NEVER the dashboard window — the panel may exceed that).
        x = min(max(x, screen.minX), screen.maxX - w)
        y = min(max(y, screen.minY), screen.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// owner D2 / sol#2 fix — reframe an ALREADY-placed panel to a new natural size while PRESERVING its origin
    /// (never re-anchoring to the cursor), capping the size to the usable `screen` and clamping the origin so the
    /// panel stays FULLY inside it. This is the origin-preserving counterpart to `frame(mouse:…)`: the in-place
    /// data-refresh path (`refreshContentInPlace`) must cap the size just like the cursor-relative path does —
    /// otherwise an oversized preview (natural width > screen) is placed partly off-screen. Pure display geometry;
    /// like `frame` it is NEVER read back into hover resolution (STOP contract).
    public static func reframe(origin: CGPoint, naturalSize: CGSize, screen: CGRect) -> CGRect {
        let w = min(naturalSize.width, screen.width)
        let h = min(naturalSize.height, screen.height)
        let x = min(max(origin.x, screen.minX), screen.maxX - w)
        let y = min(max(origin.y, screen.minY), screen.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// Usage-M3 A1 — presentation OPENING authority (owner mechanism correction 2026-09-25). The per-caller `mayOpen`
/// boolean proved too easy to misroute: a geometry `setRows` scheduled a grace whose DEFERRED `renderNow` lost the
/// "geometry" provenance and re-opened a hidden panel — the 3rd occurrence of the same family (grok-r2 direct,
/// grok-r3 visible-switch regression, luna/sol-r4 deferred grace). Authority is now decided by EVENT SEMANTIC and is
/// default-CLOSED: a HIDDEN panel may become visible ONLY from a positive user-anchor event happening NOW —
/// (1) the pointer resolving to `.row(...)`, or (2) a focus GAIN. EVERY other trigger — pointer→`.none`, focus
/// loss/blur, geometry (`setRows`/`rowDisappeared`), Esc, the grace timer, data refresh, and any FUTURE caller — is
/// `.syncOnly`: it may reposition/switch/hide an ALREADY-visible panel but must NEVER open a hidden one. Pure +
/// unit-tested; the controller checks eligibility (active / key window / non-empty slice) BEFORE consulting this.
public enum HoverPresentationIntent: Equatable, Sendable {
    case syncOnly    // geometry / timer / data / Esc / blur / pointer→.none — NO authority to open a hidden panel
    case userOpen    // a positive user anchor NOW: pointer onto a row, or a focus gain
}

public enum PresentationAction: Equatable, Sendable {
    case reposition  // same key already visible → just move it (only while following the pointer)
    case present     // (re)build + show: SWITCH a visible panel to the current key, OR OPEN from a `.userOpen` event
    case ignore      // do nothing (hidden + non-userOpen, or same key visible without follow)
}

public enum PresentationGate {
    /// Decide the action for an ELIGIBLE shown key (the controller has already confirmed active + key window +
    /// non-empty slice; an ineligible key is hidden BEFORE this is consulted). Three-layer order:
    ///   1. same key already visible → reposition (only if following the pointer), else nothing;
    ///   2. a DIFFERENT key while visible → present — a VISIBLE panel must ALWAYS track the current shownKey, incl.
    ///      switches driven by geometry (e.g. a scroll-recycle `rowDisappeared` reconciling focus to a sibling);
    ///   3. HIDDEN → present ONLY on `.userOpen`; any `.syncOnly` trigger must NOT open a hidden panel.
    public static func action(isShowing: Bool, keyIsPresented: Bool, intent: HoverPresentationIntent, follow: Bool) -> PresentationAction {
        if keyIsPresented && isShowing { return follow ? .reposition : .ignore }
        if isShowing { return .present }
        return intent == .userOpen ? .present : .ignore
    }
}
