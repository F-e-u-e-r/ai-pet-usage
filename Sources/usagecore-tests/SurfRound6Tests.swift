import Foundation
@testable import UsageCore

/// Regressions from bug-surf round 6 (Colab stderr vocabulary + precommit panel).
final class SurfRound6Tests: XCTestCase {

    func testColabFailureMapsNotLoggedInFromStderr() {
        let msg = Data("""
        Warning: Could not read the OAuth token from the OS keyring (not found).
        [colab] Warning: failed to fetch compute-unit info: ...
        """.utf8)
        XCTAssertEqual(ColabCreditsEngine.classifyFailure(stderr: msg, exitCode: 1), .notLoggedIn)
    }

    func testColabFailureMapsAuthExpiredFromStderr() {
        let msg = Data("[colab] Warning: failed to fetch compute-unit info: 401 Unauthorized\n".utf8)
        XCTAssertEqual(ColabCreditsEngine.classifyFailure(stderr: msg, exitCode: 1), .authFailed)
    }

    func testColabFailureMapsTimeoutFromStderr() {
        let msg = Data("Operation 'refresh' timed out after 30.0s\n".utf8)
        XCTAssertEqual(ColabCreditsEngine.classifyFailure(stderr: msg, exitCode: 1), .timedOut)
    }
}