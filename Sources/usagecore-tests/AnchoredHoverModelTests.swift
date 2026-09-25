import Foundation
import CoreGraphics
@testable import UsageCore

// Usage-M3 A1 — ROW-ONLY hover/focus preview (owner replacement contract 2026-09-24). The card-zone
// architecture (HoverZone.card, card-frame geometry in resolution, CardFrameKey, lastPointer, geometry→FSM
// re-resolution) is DELETED. Hover resolution is now purely: pointer location → which ROW contains it (or
// none). The preview is visual-only and never participates in hover resolution. Two pure, SwiftUI-free
// pieces: `HoverZoneResolver` (point + row rects → .row/.none) and the `AnchoredHoverModel` state machine
// (fed ONE always-current `pointerMoved(to:)` plus keyboard focus, Esc, grace `commitDismiss`, hard clears).
// Expected values hand-written (never impl-as-oracle). Zero external dependency (Foundation/CoreGraphics only).
final class AnchoredHoverModelTests {
    typealias M = AnchoredHoverModel
    typealias R = HoverZoneResolver

    // MARK: FSM — show / switch / dismiss

    func testHoverShowsRow() throws {
        var m = M(); m.pointerMoved(to: .row("A"))
        XCTAssertEqual(m.shownKey, "A")
    }

    func testRowToRowSwitchImmediate() throws {
        var m = M()
        m.pointerMoved(to: .row("A")); m.pointerMoved(to: .row("B"))
        XCTAssertEqual(m.shownKey, "B")
    }

    func testPointerNoneDoesNotDismissImmediately() throws {   // grace: .none defers to commitDismiss
        var m = M()
        m.pointerMoved(to: .row("A")); m.pointerMoved(to: .none)
        XCTAssertEqual(m.shownKey, "A")
        XCTAssertTrue(m.isIdle)
    }

    func testPointerNoneThenGraceDismisses() throws {
        var m = M()
        m.pointerMoved(to: .row("A")); m.pointerMoved(to: .none)
        m.commitDismiss()
        XCTAssertNil(m.shownKey)
    }

    // MARK: FSM — focus

    func testFocusShowsRow() throws {
        var m = M(); m.focus(row: "A")
        XCTAssertEqual(m.shownKey, "A")
    }

    func testFocusHoldsPreviewWhenPointerLeaves() throws {
        var m = M()
        m.pointerMoved(to: .row("A")); m.focus(row: "A"); m.pointerMoved(to: .none)
        XCTAssertFalse(m.isIdle)
        m.commitDismiss()
        XCTAssertEqual(m.shownKey, "A")
    }

    func testBlurThenGraceDismisses() throws {
        var m = M()
        m.focus(row: "A"); m.blur(row: "A")
        XCTAssertTrue(m.isIdle)
        m.commitDismiss()
        XCTAssertNil(m.shownKey)
    }

    func testFocusRevertsAfterPointerElsewhereLeaves() throws {
        var m = M()
        m.focus(row: "A"); m.pointerMoved(to: .row("B"))   // shown = B (pointer wins)
        m.pointerMoved(to: .none); m.commitDismiss()        // pointer gone → revert to focused A
        XCTAssertEqual(m.shownKey, "A")
    }

    func testPointerWinsOverFocusWhenDiverged() throws {   // focus A but pointer on B → B shows NOW (pointer wins)
        var m = M()
        m.focus(row: "A"); m.pointerMoved(to: .row("B"))
        XCTAssertEqual(m.shownKey, "B")
    }

    // MARK: FSM — Esc + suppression (synchronous zone-based retirement; ROWS only)

    func testEscapeDismisses() throws {
        var m = M(); m.pointerMoved(to: .row("A")); m.escape()
        XCTAssertNil(m.shownKey)
    }

    func testEscapeSuppressesWhilePointerStaysInZone() throws {
        var m = M()
        m.pointerMoved(to: .row("A")); m.escape()
        m.pointerMoved(to: .row("A"))   // pointer still on A (jitter/re-report) → stays suppressed
        XCTAssertNil(m.shownKey)
    }

    func testEscapeRetiresWhenPointerLeavesToNone() throws {
        var m = M()
        m.pointerMoved(to: .row("A")); m.escape()
        m.pointerMoved(to: .none)       // leave A's zone → suppression retires synchronously
        m.pointerMoved(to: .row("A"))
        XCTAssertEqual(m.shownKey, "A")
    }

    func testEscapeRetiresWhenPointerMovesToOtherRow() throws {
        var m = M()
        m.pointerMoved(to: .row("A")); m.escape()
        m.pointerMoved(to: .row("B"))
        XCTAssertEqual(m.shownKey, "B")
    }

    func testEscapeUnderFocusClearsOnBlur() throws {
        var m = M()
        m.focus(row: "A"); m.escape()
        m.focus(row: "A")               // re-focus (still focused) → still suppressed
        XCTAssertNil(m.shownKey)
        m.blur(row: "A")                // leave focus (pointer not on A) → retire
        m.focus(row: "A")
        XCTAssertEqual(m.shownKey, "A")
    }

    func testOverlappingEscapeHonored() throws {
        var m = M()
        m.focus(row: "A"); m.escape()             // suppress A (focus stays on A)
        m.pointerMoved(to: .row("B")); m.escape() // shown B → suppress B
        m.pointerMoved(to: .none); m.commitDismiss()
        XCTAssertNil(m.shownKey)                  // A stays suppressed (focus A), B retired
    }

    // rowonly-r1 sol finding 3: Esc while the preview is shown-in-grace but the row is ALREADY unoccupied
    // (pointer left to .none) must not strand a suppression — the next fresh hover on A must show A.
    func testEscapeWhileUnoccupiedInGraceDoesNotStrand() throws {
        var m = M()
        m.pointerMoved(to: .row("A")); m.pointerMoved(to: .none)  // A shown in grace; A already unoccupied
        m.escape()                                                 // dismiss A; must NOT strand suppression
        m.pointerMoved(to: .row("A"))                              // fresh hover on A
        XCTAssertEqual(m.shownKey, "A")
    }

    // rowonly-r1 sol finding 4: an UNRELATED row disappearing during the grace window must not short-circuit
    // the grace and dismiss the shown preview early.
    func testUnrelatedRowDisappearedPreservesGrace() throws {
        var m = M()
        m.pointerMoved(to: .row("A")); m.pointerMoved(to: .none)  // A held in grace
        m.rowDisappeared("B")                                      // unrelated recycle → must NOT dismiss A
        XCTAssertEqual(m.shownKey, "A")
        m.commitDismiss()
        XCTAssertNil(m.shownKey)
    }

    // rowonly-r1 a3 sol: after a focused row A is masked by an Esc-suppressed pointer row B, once B's
    // suppression retires (pointer leaves), commitDismiss must reconcile to the still-focused A (the FSM
    // contract the view's frame-invalidation fix relies on — it schedules that commit via `!isIdle`).
    func testFocusFallbackReconcilesAfterSuppressedPointerRetires() throws {
        var m = M()
        m.focus(row: "A")                       // A focused + shown
        m.pointerMoved(to: .row("B"))           // B shown (pointer wins), A still focused
        m.escape()                              // suppress B; shownKey nil (B held while pointer on B)
        XCTAssertNil(m.shownKey)
        XCTAssertFalse(m.isIdle)                // not idle — focus A latent
        m.pointerMoved(to: .none)               // pointer leaves B → B suppression retires
        m.commitDismiss()                       // grace fires → reconcile to focused A
        XCTAssertEqual(m.shownKey, "A")
    }

    // MARK: FSM — lifecycle (recycle / hard clear)

    func testForceDismissClearsAll() throws {
        var m = M()
        m.pointerMoved(to: .row("A")); m.forceDismiss()
        XCTAssertNil(m.shownKey)
        XCTAssertTrue(m.isIdle)
        m.pointerMoved(to: .row("A"))   // fresh hover works, no lingering suppression
        XCTAssertEqual(m.shownKey, "A")
    }

    func testRowDisappearedClearsShown() throws {
        var m = M()
        m.pointerMoved(to: .row("A")); m.rowDisappeared("A")
        XCTAssertNil(m.shownKey)
    }

    func testRowDisappearedOtherRowNoEffect() throws {
        var m = M()
        m.pointerMoved(to: .row("A")); m.rowDisappeared("B")
        XCTAssertEqual(m.shownKey, "A")
    }

    // MARK: Resolver (pure: point + ROW geometry → zone; NO card zone)

    func testResolverPointInRow() throws {
        let rows = ["A": CGRect(x: 0, y: 0, width: 100, height: 20),
                    "B": CGRect(x: 0, y: 20, width: 100, height: 20)]
        XCTAssertEqual(R.zone(at: CGPoint(x: 50, y: 30), rowRects: rows), .row("B"))
    }

    func testResolverPointInNeither() throws {
        let rows = ["A": CGRect(x: 0, y: 0, width: 100, height: 20)]
        XCTAssertEqual(R.zone(at: CGPoint(x: 200, y: 200), rowRects: rows), .none)
    }

    func testResolverPointInGapIsNone() throws {   // gap between non-contiguous rows → none
        let rows = ["A": CGRect(x: 0, y: 0, width: 100, height: 20),
                    "B": CGRect(x: 0, y: 40, width: 100, height: 20)]   // gap 20..40
        XCTAssertEqual(R.zone(at: CGPoint(x: 50, y: 30), rowRects: rows), .none)
    }

    // MARK: Panel placement (pure SCREEN geometry; owner re-architecture — output-only NSPanel near the cursor)
    // AppKit screen coords: origin BOTTOM-left, y UP (matches NSScreen.visibleFrame / NSEvent.mouseLocation).

    typealias PP = PanelPlacement
    // A typical usable screen and panel for these cases.
    var screen: CGRect { CGRect(x: 0, y: 0, width: 1440, height: 900) }
    var panel: CGSize { CGSize(width: 400, height: 300) }

    func testPanelPlacementLowerRightOfCursor() throws {
        let r = PP.frame(mouse: CGPoint(x: 400, y: 600), panelSize: panel, screen: screen, gap: 14)
        XCTAssertEqual(r.minX, 414)                 // 400 + gap → right of cursor
        XCTAssertEqual(r.minY, 286)                 // 600 − 14 − 300 → below the cursor (y-up)
        XCTAssertTrue(r.minX > 400)                 // right of cursor
        XCTAssertTrue(r.maxY <= 600)                // fully below the cursor's y
    }

    func testPanelPlacementFlipsLeftNearRightEdge() throws {
        let r = PP.frame(mouse: CGPoint(x: 1400, y: 600), panelSize: panel, screen: screen, gap: 14)
        XCTAssertEqual(r.minX, 986)                 // 1400 − 14 − 400 → flipped to the cursor's left
        XCTAssertTrue(r.minX < 1400)
        XCTAssertTrue(r.maxX <= screen.maxX)
    }

    func testPanelPlacementFlipsAboveNearBottom() throws {
        let r = PP.frame(mouse: CGPoint(x: 400, y: 100), panelSize: panel, screen: screen, gap: 14)
        XCTAssertEqual(r.minY, 114)                 // 100 + 14 → flipped above (origin above the cursor, y-up)
        XCTAssertTrue(r.minY > 100)                 // panel sits above the cursor
        XCTAssertTrue(r.maxY <= screen.maxY)
    }

    func testPanelPlacementFlipsLeftAndAboveNearCorner() throws {
        let r = PP.frame(mouse: CGPoint(x: 1400, y: 100), panelSize: panel, screen: screen, gap: 14)
        XCTAssertEqual(r.minX, 986)                 // flipped left
        XCTAssertEqual(r.minY, 114)                 // flipped above
    }

    func testPanelPlacementAlwaysInsideScreen() throws {
        // Includes screen corners and beyond — every result must stay fully within the usable screen.
        for mx in [-50, 0, 1, 700, 1439, 1440, 1600] {
            for my in [-50, 0, 1, 450, 899, 900, 1200] {
                let r = PP.frame(mouse: CGPoint(x: mx, y: my), panelSize: panel, screen: screen, gap: 14)
                XCTAssertTrue(r.minX >= screen.minX, "minX \(r.minX) at (\(mx),\(my))")
                XCTAssertTrue(r.minY >= screen.minY, "minY \(r.minY) at (\(mx),\(my))")
                XCTAssertTrue(r.maxX <= screen.maxX, "maxX \(r.maxX) at (\(mx),\(my))")
                XCTAssertTrue(r.maxY <= screen.maxY, "maxY \(r.maxY) at (\(mx),\(my))")
            }
        }
    }

    // Owner falsify target: the SCREEN is the only clamp boundary — the panel MAY extend beyond the dashboard
    // window but NEVER beyond the screen. (Clamping to the dashboard frame instead would make this RED.)
    func testPanelPlacementMayExceedDashboardWindowButNotScreen() throws {
        let dashboard = CGRect(x: 200, y: 200, width: 600, height: 400)   // a small window (maxX 800)
        let r = PP.frame(mouse: CGPoint(x: 770, y: 500), panelSize: panel, screen: screen, gap: 14)
        XCTAssertTrue(r.maxX > dashboard.maxX)      // panel extends past the dashboard window's right edge
        XCTAssertTrue(r.maxX <= screen.maxX)        // but stays within the usable screen
    }

    func testPanelPlacementLargerThanScreenClamps() throws {
        let huge = CGSize(width: 2000, height: 1200)
        let r = PP.frame(mouse: CGPoint(x: 700, y: 500), panelSize: huge, screen: screen, gap: 14)
        XCTAssertEqual(r.width, screen.width)       // clamped to screen width
        XCTAssertEqual(r.height, screen.height)     // clamped to screen height
        XCTAssertEqual(r.minX, screen.minX)
        XCTAssertEqual(r.minY, screen.minY)
    }

    // owner spike#3 #4: a SECONDARY monitor to the left of the primary — visibleFrame with NEGATIVE X and a
    // non-zero (menu-bar/dock) origin. Multi-screen is where screen-coordinate code most easily leaks; the panel
    // must still stay entirely inside THAT screen (clamped to its visibleFrame, never the dashboard window).
    func testPanelPlacementSecondaryScreenNegativeOriginStaysInside() throws {
        let secondary = CGRect(x: -1920, y: 100, width: 1920, height: 1000)   // maxX = 0, minY = 100
        let r = PP.frame(mouse: CGPoint(x: -100, y: 600),
                         panelSize: CGSize(width: 500, height: 300), screen: secondary, gap: 14)
        XCTAssertTrue(r.minX >= secondary.minX, "minX \(r.minX) < \(secondary.minX)")
        XCTAssertTrue(r.maxX <= secondary.maxX, "maxX \(r.maxX) > \(secondary.maxX)")
        XCTAssertTrue(r.minY >= secondary.minY, "minY \(r.minY) < \(secondary.minY)")
        XCTAssertTrue(r.maxY <= secondary.maxY, "maxY \(r.maxY) > \(secondary.maxY)")
        XCTAssertTrue(r.minX < -100, "near the secondary's right edge → flips left of cursor")
    }

    // owner D2 / sol#2 fix — PanelPlacement.reframe: origin-preserving cap+clamp for the in-place data-refresh path
    // (refreshContentInPlace). AppKit screen coords (origin BOTTOM-left, y UP). Hand-written expected values.
    func testReframeCapsOversizedToScreenAndStaysInside() throws {
        // natural width 760 > usable screen width 700 → cap to 700 + clamp origin so it stays fully inside.
        let r = PP.reframe(origin: CGPoint(x: 0, y: 0), naturalSize: CGSize(width: 760, height: 500),
                           screen: CGRect(x: 0, y: 0, width: 700, height: 900))
        XCTAssertEqual(r.width, 700)                 // capped to screen width (the buggy uncapped path gave 760)
        XCTAssertEqual(r.height, 500)                // fits → unchanged
        XCTAssertTrue(r.minX >= 0)                   // the buggy path put origin.x at −60 (off-screen left)
        XCTAssertTrue(r.maxX <= 700)                 // fully inside the usable screen
    }

    func testReframePreservesOriginWhenItFits() throws {
        let r = PP.reframe(origin: CGPoint(x: 100, y: 120), naturalSize: CGSize(width: 400, height: 300),
                           screen: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(r.minX, 100)                  // origin preserved (never re-anchored to the cursor)
        XCTAssertEqual(r.minY, 120)
        XCTAssertEqual(r.width, 400)
        XCTAssertEqual(r.height, 300)
    }

    func testReframeClampsOriginToStayInside() throws {
        // origin near the top-right → clamp so the panel stays fully within the screen.
        let r = PP.reframe(origin: CGPoint(x: 1300, y: 800), naturalSize: CGSize(width: 400, height: 300),
                           screen: CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(r.minX, 1040)                 // 1440 − 400
        XCTAssertEqual(r.minY, 600)                  // 900 − 300
        XCTAssertTrue(r.maxX <= 1440)
        XCTAssertTrue(r.maxY <= 900)
    }

    // owner mechanism correction 2026-09-25 — PresentationGate.action: HIDDEN opens ONLY on `.userOpen` (pointer→row /
    // focus-gain NOW); every `.syncOnly` trigger (geometry / grace timer / data / Esc / blur / pointer→.none) may
    // reposition/switch/hide a VISIBLE panel but must NEVER open a HIDDEN one. Pins the owner's presentation matrix.

    // hidden + syncOnly → NEVER open. Also pins the CORE decision of the two negative-event regressions: (A) leaving a
    // lingering no-usage row into blank = pointer→.none = syncOnly; (B) focus leaving a lingering no-usage row =
    // focus-loss = syncOnly — both must stay hidden. Covers: hidden + geometry/grace/Esc/blur/pointer-none/data.
    func testGateHiddenSyncOnlyNeverOpens() throws {
        XCTAssertEqual(PresentationGate.action(isShowing: false, keyIsPresented: false, intent: .syncOnly, follow: false), .ignore)
        XCTAssertEqual(PresentationGate.action(isShowing: false, keyIsPresented: true,  intent: .syncOnly, follow: true),  .ignore)
    }

    // hidden + userOpen → open (pointer onto a row / focus gain — the ONLY two ways a hidden panel becomes visible).
    func testGateHiddenUserOpenOpens() throws {
        XCTAssertEqual(PresentationGate.action(isShowing: false, keyIsPresented: false, intent: .userOpen, follow: false), .present)
    }

    // visible + a DIFFERENT key → switch, EVEN from a geometry (.syncOnly) trigger (grok-r3: rowDisappeared A→B).
    func testGateVisibleSwitchesToNewKeyEvenSyncOnly() throws {
        XCTAssertEqual(PresentationGate.action(isShowing: true, keyIsPresented: false, intent: .syncOnly, follow: false), .present)
        XCTAssertEqual(PresentationGate.action(isShowing: true, keyIsPresented: false, intent: .userOpen, follow: false), .present)
    }

    // visible + same key → reposition only while following the pointer; otherwise do nothing.
    func testGateVisibleSameKeyRepositionsOnlyWhenFollowing() throws {
        XCTAssertEqual(PresentationGate.action(isShowing: true, keyIsPresented: true, intent: .syncOnly, follow: true),  .reposition)
        XCTAssertEqual(PresentationGate.action(isShowing: true, keyIsPresented: true, intent: .userOpen, follow: false), .ignore)
    }
}
