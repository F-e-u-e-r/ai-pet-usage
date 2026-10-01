import Foundation
@testable import UsageCore

// Usage-M3 A1 — Projects bottom-inspector selection contract (owner ruling 2026-09-29, Phase 1).
//
// ⚠️ NOT REGISTERED (Phase 1). The runner only executes suites registered in `Sources/usagecore-tests/main.swift`,
// one of the 8 byte-frozen Appearance V1 files, so this suite COMPILES with the target but does NOT run and is NOT
// counted in the usagecore-tests assertion total. The identical assertions are exercised (green + falsification
// arms) by the standalone harness recorded under reviews/a1-bottom-inspector/. Phase 2 (after Appearance V1 is
// merged and main.swift unfrozen) registers it — add before `finishTestRun()`:
//
//     let projectInspectorSelection = ProjectInspectorSelectionTests()
//     runSuite("ProjectInspectorSelectionTests", [
//         ("testNextMovesDownInCurrentOrder", projectInspectorSelection.testNextMovesDownInCurrentOrder),
//         ("testPreviousMovesUpInCurrentOrder", projectInspectorSelection.testPreviousMovesUpInCurrentOrder),
//         ("testBoundariesStopWithoutWrap", projectInspectorSelection.testBoundariesStopWithoutWrap),
//         ("testSingleProjectStaysPut", projectInspectorSelection.testSingleProjectStaysPut),
//         ("testNilSelectionIsInert", projectInspectorSelection.testNilSelectionIsInert),
//         ("testStaleOrMissingSelectionFailsClosed", projectInspectorSelection.testStaleOrMissingSelectionFailsClosed),
//         ("testReorderedListUsesNewOrder", projectInspectorSelection.testReorderedListUsesNewOrder),
//         ("testRetainedKeepsSurvivingSelection", projectInspectorSelection.testRetainedKeepsSurvivingSelection),
//         ("testRetainedClearsRemovedSelection", projectInspectorSelection.testRetainedClearsRemovedSelection),
//         ("testRetainedNeverResurrects", projectInspectorSelection.testRetainedNeverResurrects),
//     ])
//
// Convention matches the other suites: plain class + XCTAssert* shims from TestHarness.swift (executable target —
// no XCTest module). Expected values are hand-written, never the implementation used as its own oracle.
final class ProjectInspectorSelectionTests {

    private let abc = ["projA", "projB", "projC"]

    /// ↓ selects the next project in the current order.
    func testNextMovesDownInCurrentOrder() throws {
        XCTAssertEqual(ProjectInspectorSelection.step(.next, from: "projA", in: abc), "projB" as String?)
        XCTAssertEqual(ProjectInspectorSelection.step(.next, from: "projB", in: abc), "projC" as String?)
    }

    /// ↑ selects the previous project in the current order.
    func testPreviousMovesUpInCurrentOrder() throws {
        XCTAssertEqual(ProjectInspectorSelection.step(.previous, from: "projC", in: abc), "projB" as String?)
        XCTAssertEqual(ProjectInspectorSelection.step(.previous, from: "projB", in: abc), "projA" as String?)
    }

    /// Boundaries stop — ↑ on the first and ↓ on the last keep the selection (no wrap-around).
    func testBoundariesStopWithoutWrap() throws {
        XCTAssertEqual(ProjectInspectorSelection.step(.previous, from: "projA", in: abc), "projA" as String?,
                       "↑ on the first project must stay on it, not wrap to the last")
        XCTAssertEqual(ProjectInspectorSelection.step(.next, from: "projC", in: abc), "projC" as String?,
                       "↓ on the last project must stay on it, not wrap to the first")
    }

    /// A one-project list: both directions stay on that project.
    func testSingleProjectStaysPut() throws {
        XCTAssertEqual(ProjectInspectorSelection.step(.next, from: "projA", in: ["projA"]), "projA" as String?)
        XCTAssertEqual(ProjectInspectorSelection.step(.previous, from: "projA", in: ["projA"]), "projA" as String?)
    }

    /// No selection → keys are inert: never select the first/last project on their own.
    func testNilSelectionIsInert() throws {
        XCTAssertNil(ProjectInspectorSelection.step(.next, from: nil, in: abc), "↓ without a selection must not select")
        XCTAssertNil(ProjectInspectorSelection.step(.previous, from: nil, in: abc), "↑ without a selection must not select")
    }

    /// A selected id that is not in the current list fails closed (nil = close the inspector), never jumps to a row.
    func testStaleOrMissingSelectionFailsClosed() throws {
        XCTAssertNil(ProjectInspectorSelection.step(.next, from: "gone", in: abc))
        XCTAssertNil(ProjectInspectorSelection.step(.previous, from: "gone", in: abc))
        XCTAssertNil(ProjectInspectorSelection.step(.next, from: "projA", in: []), "empty list → nil")
    }

    /// A refresh that reorders projects: the id is kept and the NEXT keypress uses the new order.
    func testReorderedListUsesNewOrder() throws {
        let reordered = ["projC", "projA", "projB"]
        XCTAssertEqual(ProjectInspectorSelection.step(.next, from: "projA", in: reordered), "projB" as String?)
        XCTAssertEqual(ProjectInspectorSelection.step(.previous, from: "projA", in: reordered), "projC" as String?)
    }

    /// Same-timeframe refresh: a selected project that is still listed (even at a new position) stays selected.
    func testRetainedKeepsSurvivingSelection() throws {
        XCTAssertEqual(ProjectInspectorSelection.retained("projB", in: ["projC", "projB", "projA"]), "projB" as String?)
    }

    /// Same-timeframe refresh: a selected project that left the list is cleared (inspector closes).
    func testRetainedClearsRemovedSelection() throws {
        XCTAssertNil(ProjectInspectorSelection.retained("projB", in: ["projA", "projC"]))
        XCTAssertNil(ProjectInspectorSelection.retained("projB", in: []), "empty refreshed list → cleared")
    }

    /// A cleared selection is never resurrected by a refresh.
    func testRetainedNeverResurrects() throws {
        XCTAssertNil(ProjectInspectorSelection.retained(nil, in: abc))
    }
}
