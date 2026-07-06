import Foundation

// 極簡測試骨架:此機器的 CommandLineTools 未附 XCTest / swift-testing,
// 故以介面對齊 XCTest 的方式自建,未來安裝完整工具鏈後可直接遷回 swift test。

final class TestRun {
    static var failures = 0
    static var assertions = 0
    static var currentTest = ""

    static func fail(_ message: String, file: StaticString, line: UInt) {
        failures += 1
        print("  ✗ \(currentTest) — \(message)  (\(file):\(line))")
    }
}

class XCTestCase {
    required init() {}
}

func XCTAssertTrue(_ value: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    TestRun.assertions += 1
    if !value { TestRun.fail(message.isEmpty ? "expected true" : message, file: file, line: line) }
}

func XCTAssertFalse(_ value: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    XCTAssertTrue(!value, message.isEmpty ? "expected false" : message, file: file, line: line)
}

func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    TestRun.assertions += 1
    if a != b { TestRun.fail("\(a) != \(b)\(message.isEmpty ? "" : " — \(message)")", file: file, line: line) }
}

func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double, _ message: String = "",
                    file: StaticString = #file, line: UInt = #line) {
    TestRun.assertions += 1
    if abs(a - b) > accuracy { TestRun.fail("\(a) != \(b) ±\(accuracy)\(message.isEmpty ? "" : " — \(message)")", file: file, line: line) }
}

func XCTAssertNil(_ value: Any?, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    TestRun.assertions += 1
    if value != nil { TestRun.fail("expected nil, got \(value!)\(message.isEmpty ? "" : " — \(message)")", file: file, line: line) }
}

func XCTAssertNotNil(_ value: Any?, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    TestRun.assertions += 1
    if value == nil { TestRun.fail(message.isEmpty ? "unexpected nil" : message, file: file, line: line) }
}

func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, _ message: String = "",
                                         file: StaticString = #file, line: UInt = #line) {
    TestRun.assertions += 1
    if !(a > b) { TestRun.fail("\(a) is not > \(b)\(message.isEmpty ? "" : " — \(message)")", file: file, line: line) }
}

func runSuite(_ name: String, _ tests: [(String, () throws -> Void)]) {
    print("▸ \(name)")
    for (testName, body) in tests {
        TestRun.currentTest = testName
        let before = TestRun.failures
        do {
            try body()
        } catch {
            TestRun.fail("threw \(error)", file: #file, line: #line)
        }
        if TestRun.failures == before { print("  ✓ \(testName)") }
    }
}

func finishTestRun() -> Never {
    print(String(repeating: "─", count: 48))
    if TestRun.failures == 0 {
        print("PASS — \(TestRun.assertions) assertions")
        exit(0)
    } else {
        print("FAIL — \(TestRun.failures) failure(s) across \(TestRun.assertions) assertions")
        exit(1)
    }
}
