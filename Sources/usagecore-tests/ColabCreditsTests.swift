import Foundation
import UsageCore
import PetCore

final class ColabCreditsTests: XCTestCase {

    private let sampleStdout = """
    Current balance: 169.77 compute units
    Usage rate: 6.73/hr
    Active assignments: 1
    """

    func testParseHappyPath() {
        let now = date("2026-11-22T10:00:00Z")
        let out = ColabCreditsEngine.parse(stdout: Data(sampleStdout.utf8), now: now)
        guard case .success(let snap) = out else {
            XCTAssertTrue(false, "expected success")
            return
        }
        XCTAssertEqual(snap.balanceUnits, 169.77, accuracy: 0.001)
        XCTAssertEqual(snap.consumptionRatePerHour, 6.73, accuracy: 0.001)
        XCTAssertEqual(snap.activeAssignments, 1)
        XCTAssertEqual(snap.fetchedAt, now)
    }

    func testParseFailClosed() {
        let now = date("2026-11-22T10:00:00Z")
        XCTAssertEqual(ColabCreditsEngine.parse(stdout: Data("Current balance: x compute units\n".utf8), now: now),
                         ColabCreditsOutcome.badReply)
        XCTAssertEqual(ColabCreditsEngine.parse(stdout: Data(), now: now), ColabCreditsOutcome.badReply)
        let huge = Data(repeating: 0x41, count: ColabCreditsEngine.maxOutputBytes + 1)
        XCTAssertEqual(ColabCreditsEngine.parse(stdout: huge, now: now), ColabCreditsOutcome.badReply)
    }

    func testPresentationSuccessAndStale() {
        let now = date("2026-11-22T12:00:00Z")
        let snap = ColabCreditsSnapshot(balanceUnits: 100, consumptionRatePerHour: 2.5,
                                        activeAssignments: 0, fetchedAt: now.addingTimeInterval(-31 * 60))
        let st = ColabCreditsStatus(snapshot: snap, lastAttemptAt: now, lastOutcome: .success(snap))
        let fresh = st.presentation(now: now.addingTimeInterval(-29 * 60))
        XCTAssertFalse(fresh.stale)
        XCTAssertEqual(fresh.primary, "100.00 CU")
        let stale = st.presentation(now: now)
        XCTAssertTrue(stale.stale)
        XCTAssertEqual(stale.bubbleUsageLine, "Colab 100.00 CU · 31m")
    }

    func testPresentationErrors() {
        let st = ColabCreditsStatus(lastOutcome: .notLoggedIn)
        let p = st.presentation(now: Date())
        XCTAssertEqual(p.primary, "not signed in — run colab once")
        XCTAssertNil(p.bubbleUsageLine)
    }

    func testFetcherInjectedRun() {
        let now = date("2026-11-22T10:00:00Z")
        let dummy = URL(fileURLWithPath: "/tmp/colab")
        let out = ColabCreditsFetcher.fetch(
            now: now,
            executableURL: dummy,
            run: { _ in Data(self.sampleStdout.utf8) })
        guard case .success(let snap) = out else {
            XCTAssertTrue(false, "expected success")
            return
        }
        XCTAssertEqual(snap.balanceUnits, 169.77, accuracy: 0.001)
    }

    func testFetcherMissingBinaryNeverSpawns() {
        let out = ColabCreditsFetcher.fetch(
            executableURL: nil,
            run: { _ in Data() })
        XCTAssertEqual(out, ColabCreditsOutcome.cliMissing)
    }

    func testClassifyFailureVocabulary() {
        let adc = Data("No valid default credentials found. To authenticate, run:\n".utf8)
        XCTAssertEqual(ColabCreditsEngine.classifyFailure(stderr: adc, exitCode: 1), .notLoggedIn)
        XCTAssertEqual(ColabCreditsEngine.classifyFailure(stderr: Data(), exitCode: 1), .authFailed)
        XCTAssertEqual(ColabCreditsEngine.classifyFailure(stderr: Data(), exitCode: 0), .badReply)
    }

    func testBubbleComposeWithColabExtra() {
        let lines = BubblePages.compose(providerLines: ["CC 12% 5h"], extraLine: "Colab 50.00 CU")
        XCTAssertEqual(lines, ["CC 12% 5h", "Colab 50.00 CU"])
    }
}