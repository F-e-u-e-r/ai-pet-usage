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

    /// Verbose stderr on exit 0 must not fill the pipe and stall the fetch (agy /usage class of bug).
    func testColabFetchDrainsStderrWhilePrintingStdout() throws {
        let dir = makeTempDir()
        let out = """
        Current balance: 10 compute units
        Usage rate: 1/hr
        Active assignments: 0
        """
        let script = dir.appendingPathComponent("colab")
        let scriptBody = """
        #!/bin/sh
        printf '%s' '\(out)'
        i=0
        while [ $i -lt 200000 ]; do printf 'w'; i=$((i+1)); done >&2
        exit 0
        """
        try scriptBody.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let started = Date()
        let result = ColabCreditsFetcher.fetch(executableURL: script)
        guard case .success(let snap) = result else {
            XCTAssertTrue(false, "expected success, got \(result)")
            return
        }
        XCTAssertEqual(snap.balanceUnits, 10, accuracy: 0.01)
        XCTAssertTrue(Date().timeIntervalSince(started) < 10, "must not hit the 25s timeout")
    }

    func testColabFetchRejectsOversizedStdout() throws {
        let dir = makeTempDir()
        let lines = """
        Current balance: 10 compute units
        Usage rate: 1/hr
        Active assignments: 0
        """
        let pad = String(repeating: "x", count: ColabCreditsEngine.maxOutputBytes)
        let script = dir.appendingPathComponent("colab")
        let scriptBody = """
        #!/bin/sh
        printf '%s\\n%s' '\(lines)' '\(pad)'
        exit 0
        """
        try scriptBody.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        XCTAssertEqual(ColabCreditsFetcher.fetch(executableURL: script), .badReply)
    }

    func testColabFetchRejectsOversizedStderrOnExit1() throws {
        let dir = makeTempDir()
        let pad = String(repeating: "n", count: ColabCreditsEngine.maxOutputBytes)
        let script = dir.appendingPathComponent("colab")
        let scriptBody = """
        #!/bin/sh
        printf '%s' '\(pad)' >&2
        printf '401 Unauthorized\\n' >&2
        exit 1
        """
        try scriptBody.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        XCTAssertEqual(ColabCreditsFetcher.fetch(executableURL: script), .badReply)
    }

    func testColabFetchClassifiesTimeoutFromStderrOnExit1() throws {
        let dir = makeTempDir()
        let script = dir.appendingPathComponent("colab")
        let scriptBody = """
        #!/bin/sh
        printf 'Operation '"'"'refresh'"'"' timed out after 30.0s\\n' >&2
        exit 1
        """
        try scriptBody.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let result = ColabCreditsFetcher.fetch(executableURL: script)
        XCTAssertEqual(result, ColabCreditsOutcome.timedOut)
    }
}