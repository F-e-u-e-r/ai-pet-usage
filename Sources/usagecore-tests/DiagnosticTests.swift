import Foundation
import UsageCore

// MARK: - Redaction(最後安全網;非隱私保證)

final class RedactionTests: XCTestCase {
    let home = "/Users/alice"

    func testHomePrefixToTilde() throws {
        XCTAssertEqual(Redaction.scrub("/Users/alice/.codex/x", home: home), "~/.codex/x")
    }

    func testHomeBoundaryDoesNotEatOtherUser() throws {
        // /Users/alice2 不是 /Users/alice 的家目錄;不可被當成 ~,但仍應被通用規則去識別化。
        let out = Redaction.scrub("/Users/alice2/secret", home: home)
        XCTAssertFalse(out.contains("alice"), "other user name must not survive: \(out)")
        XCTAssertEqual(out, "~/secret")
    }

    func testOtherUsersPathRedacted() throws {
        XCTAssertEqual(Redaction.scrub("open /Users/bob/proj/log.jsonl", home: home), "open ~/proj/log.jsonl")
    }

    func testNonHomeAbsolutePathsRedacted() throws {
        XCTAssertEqual(Redaction.scrub("at /Volumes/ClientX/AcmeSecret/log", home: home), "at ‹redacted-path›")
        XCTAssertEqual(Redaction.scrub("tmp /private/var/folders/xy/z.jsonl", home: home), "tmp ‹redacted-path›")
    }

    func testTokenPatternsRedacted() throws {
        let out = Redaction.scrub("key sk-ABCDEF0123456789ghij done", home: home)
        XCTAssertTrue(out.contains("‹redacted-token›"), out)
        XCTAssertFalse(out.contains("sk-ABCDEF"), out)
    }

    func testOrdinaryTextUntouched() throws {
        let s = "used 91.7% of weekly, 300m window, resets in 42m"
        XCTAssertEqual(Redaction.scrub(s, home: home), s)
    }

    func testIdempotent() throws {
        let s = "/Users/alice/.codex and /Volumes/X/y and sk-ABCDEF0123456789ghij"
        let once = Redaction.scrub(s, home: home)
        XCTAssertEqual(Redaction.scrub(once, home: home), once)
    }
}

// MARK: - Diagnostic report(封閉詞彙 + leak-proof)

final class DiagnosticReportTests: XCTestCase {
    let home = "/Users/alice"

    // 以哨兵值填滿「舊設計會外洩」的每個自由字串欄位。
    private func sentinelDashboard(now: Date) -> DashboardState {
        var dash = DashboardState.empty
        dash.snapshots = [
            UsageSnapshot(
                providerId: "codex", displayName: "Codex", status: .healthy,
                updatedAt: now.addingTimeInterval(-120),
                tokenInput: 100, tokenOutput: 50, tokenCache: 10,
                sourceDescription: "found /Volumes/ClientX/AcmeSecretProject",   // 哨兵:collect 不讀
                errorMessage: "crashed reading /Users/alice/.codex/rollout-x.jsonl SUPERSECRETPROMPT"), // 哨兵
            UsageSnapshot(
                providerId: "grok-code", displayName: "Grok Code", status: .noData,
                sourceDescription: "n/a"),                                        // noData → tokens 應為 nil
            UsageSnapshot(
                providerId: "mystery-provider", displayName: "Mystery", status: .healthy,
                sourceDescription: "x"),                                          // 未知 id → 丟棄
        ]
        dash.limitStates = [
            ProviderLimitState(
                providerId: "codex",
                fiveHour: LimitWindowState(usedPercent: 91.7, resetAt: now.addingTimeInterval(3600),
                                           windowMinutes: 300, confidence: .high),
                weekly: LimitWindowState(usedPercent: nil, windowMinutes: 10080,
                                         confidence: .unknown, idle: true)),      // idle → 不得 render 0
        ]
        dash.dataQuality = [
            "codex: parse failed near AcmeSecretLaunchPlan",                      // 哨兵 → .other,零文字
            "codex: 3 unparsable line(s) skipped on last scan",                  // → unparsableLines count 3
            "refresh skipped — another AI Pet Usage process (app or CLI) holds the data lock",
            // corrected-downward 內嵌絕對本地時間;分類為 correctedRecently 並丟棄整個含時間的後綴。
            "codex: weekly usage percent corrected downward — confirmed official readings at 2026-07-15 09:12:00 (UTC+8)",
            // 未知 pid 前綴 + 尾巴像樣板 → 必須落到 .other(不因尾巴而回傳已知碼),且路徑不得洩漏。
            "bogusprov: refresh error — boom at /Users/alice/secret",
        ]
        dash.topProjects = [                                                      // 哨兵:collect 不讀 topProjects
            ProjectSummary(projectId: "/Volumes/ClientX/AcmeSecretProject", projectName: "AcmeSecretProject",
                           tokens: .zero, cost: .zero, providers: ["codex"],
                           topModel: nil, lastActive: now, shareOfPeriod: 1.0),
        ]
        return dash
    }

    private func sentinelSources() -> [DiagnosticSourceState] {
        [DiagnosticSourceState(id: .codexSessions, state: .present, modifiedAge: .under5m),
         DiagnosticSourceState(id: .grokSessions, state: .missing, modifiedAge: nil)]
    }

    private func collect(now: Date, dashboard: DashboardState? = nil,
                         sources: [DiagnosticSourceState]? = nil,
                         settings: CoreSettings? = nil) -> DiagnosticReport {
        DiagnosticReport.collect(
            dashboard: dashboard ?? sentinelDashboard(now: now),
            sourceStates: sources ?? sentinelSources(),
            settings: settings ?? CoreSettings(),
            app: DiagnosticAppInfo(version: "0.1.6", channel: .release, os: "14.5.0"),
            now: now)
    }

    private let leaks = ["/Users/", "/Volumes/ClientX", "AcmeSecretProject", "AcmeSecretLaunchPlan",
                         "SUPERSECRETPROMPT", "rollout-x.jsonl", "09:12:00", "2026-07-15 09:12"]

    func testTextHasNoLeaks() throws {
        let out = collect(now: Date(timeIntervalSince1970: 1_700_000_000)).renderText(home: home)
        for s in leaks { XCTAssertFalse(out.contains(s), "text leaked \(s):\n\(out)") }
    }

    func testJSONHasNoLeaks() throws {
        let out = collect(now: Date(timeIntervalSince1970: 1_700_000_000)).renderJSON(home: home)
        for s in leaks { XCTAssertFalse(out.contains(s), "json leaked \(s):\n\(out)") }
    }

    func testAllowListedContentPresent() throws {
        let out = collect(now: Date(timeIntervalSince1970: 1_700_000_000)).renderText(home: home)
        XCTAssertTrue(out.contains("Codex"), out)
        XCTAssertTrue(out.contains("91.7%"), "exact percent must survive (not truncated): \(out)")
        XCTAssertTrue(out.contains("~/.codex/sessions"), "source label present: \(out)")
        XCTAssertTrue(out.contains("refreshFailed"), "error surfaced as code: \(out)")
    }

    func testUnknownProviderDropped() throws {
        let out = collect(now: Date(timeIntervalSince1970: 1_700_000_000)).renderJSON(home: home)
        XCTAssertFalse(out.contains("mystery-provider"), out)
        XCTAssertFalse(out.contains("Mystery"), out)
    }

    func testMissingTokensAreNilNotZero() throws {
        // grok-code 為 noData → 不得出現 token 數字(尤其不得偽造 0)。
        let report = collect(now: Date(timeIntervalSince1970: 1_700_000_000))
        let grok = report.providers.first { $0.id == "grok-code" }
        XCTAssertNotNil(grok)
        XCTAssertNil(grok?.input)
        XCTAssertNil(grok?.output)
        XCTAssertNil(grok?.cache)
    }

    func testIdleWindowNeverRendersZero() throws {
        let report = collect(now: Date(timeIntervalSince1970: 1_700_000_000))
        let codex = report.providers.first { $0.id == "codex" }
        XCTAssertNotNil(codex?.weekly)
        XCTAssertTrue(codex?.weekly?.idle == true)
        XCTAssertNil(codex?.weekly?.usedPercent, "idle must keep nil percent, never 0")
        let text = report.renderText(home: home)
        XCTAssertTrue(text.contains("idle (no active 5h window)"), text)
        // JSON:idle 的 usedPercent 必須是顯式 null(而非省略、更非 0)。
        let json = report.renderJSON(home: home)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let providers = obj?["providers"] as? [[String: Any]]
        let codexJSON = providers?.first { ($0["id"] as? String) == "codex" }
        let weekly = codexJSON?["weekly"] as? [String: Any]
        XCTAssertTrue(weekly?.keys.contains("usedPercent") == true, "usedPercent key must be present")
        XCTAssertTrue(weekly?["usedPercent"] is NSNull, "idle usedPercent must be JSON null, not 0/omitted")
    }

    func testEnabledProvidersClosedFilter() throws {
        // 手改 settings.json 塞入的未知 provider id 不得回顯(封閉詞彙)。
        var s = CoreSettings()
        s.enabledProviders = ["codex", "AcmeSecretLaunchPlan"]
        let report = collect(now: Date(timeIntervalSince1970: 1_700_000_000), settings: s)
        XCTAssertEqual(report.settings.enabledProviders, ["codex"])
        let out = report.renderJSON(home: home) + report.renderText(home: home)
        XCTAssertFalse(out.contains("AcmeSecretLaunchPlan"), "unknown enabled-provider id leaked: \(out)")
    }

    func testInProcessReadOnlyNoMutation() throws {
        // readOnly coordinator 的 init 是唯一建目錄點(ensureDirectory);readOnly 時必須略過。
        let ghost = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aipet-inproc-\(ProcessInfo.processInfo.processIdentifier)-ghost")
        try? FileManager.default.removeItem(at: ghost)
        defer { try? FileManager.default.removeItem(at: ghost) }
        _ = UsageCoordinator(dataDir: ghost, settings: CoreSettings(), readOnly: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ghost.path),
                       "readOnly coordinator init must not create the data directory")
        // 對照:非 readOnly 的 init 會建立目錄(確認測試確實在測 readOnly 的效果)。
        let ghost2 = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aipet-inproc-\(ProcessInfo.processInfo.processIdentifier)-rw")
        try? FileManager.default.removeItem(at: ghost2)
        defer { try? FileManager.default.removeItem(at: ghost2) }
        _ = UsageCoordinator(dataDir: ghost2, settings: CoreSettings(), readOnly: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ghost2.path),
                      "non-readOnly init should create the dir (control)")
    }

    func testQualityClassification() throws {
        let report = collect(now: Date(timeIntervalSince1970: 1_700_000_000))
        let codes = Set(report.quality.map { $0.code })
        XCTAssertTrue(codes.contains("unparsableLines"), "\(report.quality)")
        XCTAssertTrue(codes.contains("refreshSkippedLock"), "\(report.quality)")
        XCTAssertTrue(codes.contains("correctedRecently"), "corrected template must classify: \(report.quality)")
        XCTAssertTrue(codes.contains("other"), "unmatched/unknown-pid template must fail closed to other: \(report.quality)")
        let unparsable = report.quality.first { $0.code == "unparsableLines" }
        XCTAssertEqual(unparsable?.count, 3)
        XCTAssertEqual(unparsable?.provider, "codex")
        // correctedRecently 不得帶 provider 以外的任何欄位殘留(尤其不得有絕對時間;由 leak 測試全域把關)
        let corrected = report.quality.first { $0.code == "correctedRecently" }
        XCTAssertEqual(corrected?.provider, "codex")
        XCTAssertNil(corrected?.count)
        // 未知 pid("bogusprov")→ other,且 provider 欄位為 nil(不回顯未知 id)
        for q in report.quality {
            XCTAssertFalse((q.provider ?? "").contains("bogus"), "unknown pid echoed: \(q)")
            XCTAssertFalse((q.provider ?? "").contains("Acme"))
        }
    }

    func testDeterministicAcrossInputPermutation() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var permuted = sentinelDashboard(now: now)
        permuted.snapshots.reverse()
        permuted.dataQuality.reverse()
        permuted.limitStates.reverse()
        let a = collect(now: now, sources: sentinelSources()).renderJSON(home: home)
        let b = collect(now: now, dashboard: permuted, sources: sentinelSources().reversed()).renderJSON(home: home)
        XCTAssertEqual(a, b, "render must be byte-identical regardless of input order (snapshots/quality/limits/sources)")
    }

    func testJSONValidAndSchemaVersion() throws {
        let out = collect(now: Date(timeIntervalSince1970: 1_700_000_000)).renderJSON(home: home)
        let data = Data(out.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj)
        XCTAssertEqual(obj?["schemaVersion"] as? Int, 1)
    }

    // 子行程層級:aipet diag 對「不存在的資料目錄」必須零副作用(目錄仍不存在)。
    // 只有在已建置 .build/debug/aipet 時執行(否則略過,不失敗)。
    func testCLIDiagNoFilesystemMutation() throws {
        let cwd = FileManager.default.currentDirectoryPath
        let bin = URL(fileURLWithPath: cwd).appendingPathComponent(".build/debug/aipet")
        guard FileManager.default.fileExists(atPath: bin.path) else {
            XCTAssertTrue(true, "skipped — .build/debug/aipet not built")
            return
        }
        let tmpParent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aipet-diag-nomut-\(ProcessInfo.processInfo.processIdentifier)")
        let ghostDataDir = tmpParent.appendingPathComponent("does-not-exist-data")
        try? FileManager.default.removeItem(at: tmpParent)
        defer { try? FileManager.default.removeItem(at: tmpParent) }

        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["diag"]
        var env = ProcessInfo.processInfo.environment
        env["AIPET_DATA_DIR"] = ghostDataDir.path
        proc.environment = env
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()

        XCTAssertEqual(proc.terminationStatus, 0, "aipet diag must exit 0 (else the no-mutation check is vacuous)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ghostDataDir.path),
                       "aipet diag must not create the data directory")
    }
}
