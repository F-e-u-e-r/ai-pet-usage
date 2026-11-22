import Foundation

// Google Colab compute-unit balance (opt-in, default off) — pure logic.
// Boundary: docs/DATA_SOURCES.md «Colab credits». Zero network in this file;
// ColabCreditsChecker spawns `colab usage` (CLI performs HTTPS with cached OAuth).

// MARK: - Snapshot

public struct ColabCreditsSnapshot: Sendable, Equatable {
    public var balanceUnits: Double
    public var consumptionRatePerHour: Double
    public var activeAssignments: Int
    public var fetchedAt: Date

    public init(balanceUnits: Double, consumptionRatePerHour: Double,
                activeAssignments: Int, fetchedAt: Date) {
        self.balanceUnits = balanceUnits
        self.consumptionRatePerHour = consumptionRatePerHour
        self.activeAssignments = activeAssignments
        self.fetchedAt = fetchedAt
    }
}

public enum ColabCreditsOutcome: Sendable, Equatable {
    case success(ColabCreditsSnapshot)
    case cliMissing
    case notLoggedIn
    case authFailed
    case badReply
    case timedOut
    case networkError
}

// MARK: - Parse stdout (no I/O)

public enum ColabCreditsEngine {
    public static let maxOutputBytes = 65_536

    /// Maps non-zero `colab usage` exit + stderr into the closed outcome vocabulary (no raw stderr in UI).
    public static func classifyFailure(stderr: Data, exitCode: Int32) -> ColabCreditsOutcome {
        guard exitCode != 0 else { return .badReply }
        guard stderr.count <= maxOutputBytes else { return .badReply }
        let text = String(data: stderr, encoding: .utf8)?.lowercased() ?? ""
        if text.contains("timed out") || text.contains("timeout after") {
            return .timedOut
        }
        if text.contains("connection refused") || text.contains("network is unreachable")
            || text.contains("failed to establish") || text.contains("name or service not known") {
            return .networkError
        }
        if text.contains("no valid default credentials")
            || text.contains("could not read the oauth token")
            || text.contains("authorize colab-cli")
            || text.contains("visit this url in any browser")
            || text.contains("not logged in") {
            return .notLoggedIn
        }
        if text.contains("refresh") || text.contains("401")
            || text.contains("403") || text.contains("unauthorized")
            || text.contains("invalid_grant") || text.contains("login expired") {
            return .authFailed
        }
        // `colab usage` only prints to stderr on fetch/auth failure (exit 1).
        return .authFailed
    }

    /// Parses `colab usage` text (`consumption.format_consumption_status` shape).
    public static func parse(stdout: Data, now: Date) -> ColabCreditsOutcome {
        guard stdout.count <= maxOutputBytes else { return .badReply }
        guard let text = String(data: stdout, encoding: .utf8) else { return .badReply }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var balance: Double?
        var rate: Double?
        var active: Int?
        for line in lines {
            if line.hasPrefix("Current balance:") {
                balance = firstNumber(afterLabel: line, suffix: "compute units")
            } else if line.hasPrefix("Usage rate:") {
                rate = firstNumber(afterLabel: line, suffix: "/hr")
            } else if line.hasPrefix("Active assignments:") {
                active = firstInteger(afterLabel: line, suffix: nil)
            }
        }
        guard let balance, let rate, let active,
              balance.isFinite, rate.isFinite, rate >= 0, active >= 0 else { return .badReply }
        return .success(ColabCreditsSnapshot(balanceUnits: balance, consumptionRatePerHour: rate,
                                             activeAssignments: active, fetchedAt: now))
    }

    private static func firstNumber(afterLabel line: String, suffix: String?) -> Double? {
        var body = line
        if let colon = body.firstIndex(of: ":") {
            body = String(body[body.index(after: colon)...])
        }
        body = body.trimmingCharacters(in: .whitespaces)
        if let suffix, body.hasSuffix(suffix) {
            body = String(body.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return Double(body)
    }

    private static func firstInteger(afterLabel line: String, suffix: String?) -> Int? {
        guard let d = firstNumber(afterLabel: line, suffix: suffix) else { return nil }
        guard d.isFinite, d >= 0, d.rounded() == d else { return nil }
        return Int(d)
    }
}

// MARK: - Subprocess (test-injectable)

public enum ColabCreditsFetcher {
    public static func resolveColabBinary() -> URL? {
        if let fromShell = whichViaLoginShell("colab"),
           FileManager.default.isExecutableFile(atPath: fromShell.path) {
            return fromShell
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/colab"),
            URL(fileURLWithPath: "/opt/homebrew/bin/colab"),
            URL(fileURLWithPath: "/usr/local/bin/colab"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    /// GUI apps inherit a minimal `PATH`; login-shell `command -v` matches Terminal.
    private static func whichViaLoginShell(_ name: String) -> URL? {
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "command -v \(name)"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let line = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              line.hasPrefix("/"), line.count < 512 else { return nil }
        return URL(fileURLWithPath: line)
    }

    /// Legacy plaintext OAuth cache (pre–keyring colab-cli). Presence only — never read.
    public static func legacyTokenFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/colab-cli/token.json")
    }

    public static func fetch(
        now: Date = Date(),
        executableURL: URL? = resolveColabBinary(),
        run: ((URL) throws -> Data)? = nil
    ) -> ColabCreditsOutcome {
        guard let executableURL else { return .cliMissing }
        let runner = run ?? defaultRun
        do {
            let out = try runner(executableURL)
            return ColabCreditsEngine.parse(stdout: out, now: now)
        } catch let err as NSError where err.domain == "ColabCreditsFetcher" && err.code == -1 {
            return .timedOut
        } catch let err as ColabCreditsRunError {
            return ColabCreditsEngine.classifyFailure(stderr: err.stderr, exitCode: err.exitCode)
        } catch {
            return .networkError
        }
    }

    private struct ColabCreditsRunError: Error {
        let exitCode: Int32
        let stderr: Data
    }

    private static func defaultRun(executableURL: URL) throws -> Data {
        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = ["usage"]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        let collected = CollectedOutput()
        let exited = DispatchSemaphore(value: 0)
        let reader = out.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; collected.finish() } else { collected.append(chunk) }
        }
        proc.terminationHandler = { _ in exited.signal() }
        defer { reader.readabilityHandler = nil }
        try proc.run()
        let deadline = DispatchTime.now() + .seconds(25)
        if exited.wait(timeout: deadline) == .timedOut {
            proc.terminate()
            throw NSError(domain: "ColabCreditsFetcher", code: -1)
        }
        _ = collected.eof.wait(timeout: min(deadline, DispatchTime.now() + .seconds(2)))
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0 else {
            throw ColabCreditsRunError(exitCode: proc.terminationStatus, stderr: stderr)
        }
        return collected.snapshot()
    }

    private final class CollectedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var finished = false
        let eof = DispatchSemaphore(value: 0)

        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        func finish() {
            lock.lock(); let first = !finished; finished = true; lock.unlock()
            if first { eof.signal() }
        }
        func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}

// MARK: - Presentation

public struct ColabCreditsStatus: Sendable, Equatable {
    public var snapshot: ColabCreditsSnapshot?
    public var lastAttemptAt: Date?
    public var lastOutcome: ColabCreditsOutcome?

    public init(snapshot: ColabCreditsSnapshot? = nil,
                lastAttemptAt: Date? = nil,
                lastOutcome: ColabCreditsOutcome? = nil) {
        self.snapshot = snapshot
        self.lastAttemptAt = lastAttemptAt
        self.lastOutcome = lastOutcome
    }

    public struct Presentation: Sendable, Equatable {
        public var primary: String
        public var detail: String?
        public var age: String?
        public var stale: Bool
        public var tooltip: String
        public var bubbleUsageLine: String?
        public var bubbleDataLine: String?
    }

    public func presentation(now: Date, staleAfterMinutes: Int = 30) -> Presentation {
        if let snap = snapshot {
            let ageSeconds = now.timeIntervalSince(snap.fetchedAt)
            let ageText = Self.compactAge(seconds: ageSeconds)
            let attemptFailed = lastOutcome != nil && !Self.isSuccess(lastOutcome!)
            let stale = attemptFailed || ageSeconds > Double(staleAfterMinutes) * 60
            let bal = Self.fmtUnits(snap.balanceUnits)
            if attemptFailed {
                let line = Self.stateLine(for: lastOutcome!)
                return Presentation(
                    primary: line, detail: "last \(bal) · \(ageText)",
                    age: ageText, stale: true,
                    tooltip: "\(line). Last known balance \(bal), as of \(ageText) ago.",
                    bubbleUsageLine: nil,
                    bubbleDataLine: "Colab \(Self.shortState(for: lastOutcome!)) · \(ageText)")
            }
            let rate = Self.fmtUnits(snap.consumptionRatePerHour)
            let detail = "\(rate)/hr · \(snap.activeAssignments) active"
            let staleSuffix = stale ? " · \(ageText)" : ""
            return Presentation(
                primary: "\(bal) CU",
                detail: detail,
                age: ageText,
                stale: stale,
                tooltip: "Colab compute units: \(bal) balance, \(rate) per hour burn, "
                    + "\(snap.activeAssignments) active VM(s). As of \(ageText) ago.",
                bubbleUsageLine: "Colab \(bal) CU\(staleSuffix)",
                bubbleDataLine: "Colab reported · \(ageText)")
        }
        let line: String
        let short: String
        switch lastOutcome {
        case nil:
            line = "checking…"; short = "checking"
        case .some(let outcome):
            line = Self.stateLine(for: outcome)
            short = Self.shortState(for: outcome)
        }
        return Presentation(
            primary: line, detail: nil, age: nil, stale: lastOutcome != nil,
            tooltip: "Colab credits: \(line).",
            bubbleUsageLine: nil,
            bubbleDataLine: lastOutcome == nil ? nil : "Colab \(short)")
    }

    private static func isSuccess(_ o: ColabCreditsOutcome) -> Bool {
        if case .success = o { return true }
        return false
    }

    static func stateLine(for outcome: ColabCreditsOutcome) -> String {
        switch outcome {
        case .success: return "ok"
        case .cliMissing: return "colab CLI not found"
        case .notLoggedIn: return "not signed in — run colab once"
        case .authFailed: return "login expired — run colab once"
        case .timedOut, .networkError: return "can't reach Colab"
        case .badReply: return "unexpected output from colab"
        }
    }

    static func shortState(for outcome: ColabCreditsOutcome) -> String {
        switch outcome {
        case .success: return "ok"
        case .cliMissing: return "no CLI"
        case .notLoggedIn: return "not signed in"
        case .authFailed: return "login expired"
        case .timedOut, .networkError: return "unreachable"
        case .badReply: return "bad output"
        }
    }

    public static func fmtUnits(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    public static func compactAge(seconds: TimeInterval) -> String {
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
}