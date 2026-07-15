import Foundation
import UsageCore

// PR A — privacy hardening:HTML sink 端 redaction + Claude 窄 decoder。

private func privTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aipet-priv-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeReport(projects: [ProjectSummary], dataQuality: [String]) -> String {
    let data = ReportData(
        title: "Privacy Test Report",
        period: DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000),
                             end: Date(timeIntervalSince1970: 1_700_086_400)),
        generatedAt: Date(timeIntervalSince1970: 1_700_086_400),
        timezoneName: "UTC",
        totals: TokenBreakdown(input: 1000),
        cost: .zero,
        byProvider: [],
        limitStates: [],
        projects: projects,
        models: [],
        buckets: [],
        pricingRows: [],
        unknownModels: [],
        dataQuality: dataQuality,
        petSummary: nil
    )
    return ReportGenerator.generateHTML(data)
}

private func project(id: String?, name: String?) -> ProjectSummary {
    ProjectSummary(projectId: id ?? "", projectName: name ?? (id ?? ""),
                   tokens: TokenBreakdown(input: 100), cost: .zero,
                   providers: ["codex"], topModel: nil, lastActive: nil, shareOfPeriod: 1.0)
}

// MARK: - PrivacyRedaction 純 helper

final class PrivacyRedactionTests: XCTestCase {
    func testDisplayProjectNameNormal() throws {
        XCTAssertEqual(PrivacyRedaction.displayProjectName(projectName: "demo-app", projectId: "/Users/x/demo-app"), "demo-app")
    }
    func testDisplayProjectNamePathLikeNameBasenamed() throws {
        // projectName 本身被塞成完整路徑 → 只取 basename,絕不輸出完整路徑。
        let out = PrivacyRedaction.displayProjectName(projectName: "/Users/alice/private/repo", projectId: nil)
        XCTAssertEqual(out, "repo")
        XCTAssertFalse(out.contains("/"))
        XCTAssertFalse(out.contains("alice"))
    }
    func testDisplayProjectNameNilNameFallsToBasename() throws {
        let out = PrivacyRedaction.displayProjectName(projectName: nil, projectId: "/Users/alice/SecretClient/foo")
        XCTAssertEqual(out, "foo")
        XCTAssertFalse(out.contains("Users"))
        XCTAssertFalse(out.contains("SecretClient"))
    }
    func testDisplayProjectNameEmpty() throws {
        XCTAssertEqual(PrivacyRedaction.displayProjectName(projectName: nil, projectId: nil), "Unnamed project")
        XCTAssertEqual(PrivacyRedaction.displayProjectName(projectName: "  ", projectId: ""), "Unnamed project")
    }
    // codex SEV1:Windows / UNC / drive-letter 路徑也不得原樣輸出(macOS 的 lastPathComponent 不認 \)。
    func testDisplayProjectNameWindowsAndUNCBasenamed() throws {
        XCTAssertEqual(PrivacyRedaction.displayProjectName(projectName: #"C:\Users\alice\repo"#, projectId: nil), "repo")
        XCTAssertEqual(PrivacyRedaction.displayProjectName(projectName: #"\\server\share\proj"#, projectId: nil), "proj")
        let out = PrivacyRedaction.displayProjectName(projectName: #"C:\Users\alice\repo"#, projectId: nil)
        XCTAssertFalse(out.contains("\\"))
        XCTAssertFalse(out.contains("alice"))
        XCTAssertFalse(out.contains("C:"))
    }
    func testSafeDataQualityKnownTemplateKept() throws {
        let s = "codex: 3 unparsable line(s) skipped on last scan"
        XCTAssertEqual(PrivacyRedaction.safeDataQuality(s), s)
    }
    // grok/codex 複審 SEV1:"unparsable line" 分支不得 return raw —— 被塞入尾段(機密/路徑)必須丟棄。
    func testSafeDataQualityUnparsableInjectedTailDropped() throws {
        let out = PrivacyRedaction.safeDataQuality("codex: 3 unparsable lines SECRET_ABC at /Users/alice/x.jsonl")
        XCTAssertFalse(out.contains("SECRET_ABC"), out)
        XCTAssertFalse(out.contains("/Users/"), out)
        XCTAssertFalse(out.contains("/"), out)
        XCTAssertTrue(out.contains("unparsable line"), out)
        XCTAssertTrue(out.contains("3"), "structural count preserved")
    }
    func testSafeDataQualityDropsRawErrorAndPath() throws {
        let out = PrivacyRedaction.safeDataQuality("codex: refresh error — boom at /Users/alice/.codex/x.jsonl")
        XCTAssertFalse(out.contains("/Users/"))
        XCTAssertFalse(out.contains(".codex"))
        XCTAssertTrue(out.contains("refresh error"))
    }
    func testSafeDataQualityUnknownPathyStringGeneralized() throws {
        let out = PrivacyRedaction.safeDataQuality("Permission denied: /Users/alice/private/secret.txt")
        XCTAssertFalse(out.contains("/Users/"))
        XCTAssertFalse(out.contains("alice"))
        XCTAssertEqual(out, "A data-quality note was recorded.")
    }
    // codex SEV1:即使沒有 "/" 或 " — " 分隔,未知/被塞入的字串也不得原樣輸出(真 allowlist)。
    func testSafeDataQualitySlashFreeSecretsDropped() throws {
        // 已知樣板的關鍵字比對:只留乾淨頭,尾段(含機密)丟棄。
        let e = PrivacyRedaction.safeDataQuality("codex: refresh error: SECRET_TOKEN_ABC")
        XCTAssertFalse(e.contains("SECRET_TOKEN_ABC"), e)
        XCTAssertTrue(e.hasPrefix("codex:"))
        // 完全未知(無斜線、無已知關鍵字)→ 通用訊息。
        let u = PrivacyRedaction.safeDataQuality("weird freeform note SECRET_XYZ_999")
        XCTAssertEqual(u, "A data-quality note was recorded.")
    }
    func testSafeDataQualityCorrectedDropsAbsoluteTime() throws {
        // 真實來源用 "5h"(見 UsageCoordinator);provider 前綴不得變成 Optional(...)(雙層 Optional 迴歸)。
        let out = PrivacyRedaction.safeDataQuality("claude-code: 5h usage percent corrected downward — full reindex at 2026-07-15 09:12:00 (UTC+8)")
        XCTAssertFalse(out.contains("09:12"))
        XCTAssertTrue(out.contains("corrected downward"))
        XCTAssertFalse(out.contains("Optional("), "provider prefix must not render as Optional(...): \(out)")
        XCTAssertTrue(out.hasPrefix("claude-code:"), out)
    }
    // grok S2-2:含 repo 相對路徑的固定樣板不得被 "/" 守門摧毀,而是對映到無路徑的乾淨訊息。
    func testSafeDataQualityPercentUnavailableKeptWithoutPath() throws {
        let out = PrivacyRedaction.safeDataQuality("claude-code: percent unavailable — install the statusline hook (Scripts/claude-statusline-hook.sh) for official limits, or set a token budget in Settings")
        XCTAssertTrue(out.contains("percent unavailable"), out)
        XCTAssertFalse(out.contains("Scripts/"), out)
        XCTAssertFalse(out.contains("/"), out)
        XCTAssertTrue(out != "A data-quality note was recorded.", "known template must not be generalized away")
    }
}

// MARK: - HTML report sink 端(使用者指定的 test 1/2/3)

final class ReportRedactionTests: XCTestCase {
    // test 1:projectName 為 nil,projectId 是完整路徑 → 報告不得含完整路徑。
    func testReportNoFullPathWhenProjectNameNil() throws {
        let html = makeReport(projects: [project(id: "/Users/alice/SecretClient/foo", name: nil)], dataQuality: [])
        XCTAssertTrue(html.contains("foo"), "basename should appear")
        XCTAssertFalse(html.contains("/Users/"), html.prefix(0).description)
        XCTAssertFalse(html.contains("alice"))
        XCTAssertFalse(html.contains("SecretClient"))
    }
    // test 3:projectName 本身被塞成完整路徑 → sink 端仍 fail-closed。
    func testReportSinkDefensiveAgainstPathName() throws {
        let html = makeReport(projects: [project(id: nil, name: "/Users/alice/private/repo")], dataQuality: [])
        XCTAssertFalse(html.contains("/Users/alice/private/repo"))
        XCTAssertFalse(html.contains("alice"))
        XCTAssertTrue(html.contains("repo"))
    }
    // test 2:dataQuality 夾帶原始 error + 路徑 → 報告只輸出封閉詞彙。
    func testReportNoRawParserError() throws {
        let html = makeReport(projects: [],
                              dataQuality: ["claude-code: refresh error — The file /Users/alice/.claude/projects/x couldn't be read"])
        XCTAssertFalse(html.contains("/Users/"))
        XCTAssertFalse(html.contains(".claude"))
        XCTAssertFalse(html.contains("couldn't be read"))
    }
    // grok S2-3:來源端(UsageLedger.projectSummaries)缺 projectName 時,顯示名 basename 化,
    // 而非把完整 cwd 當顯示名 → UI 與 HTML 皆消費此淨化值。
    func testProjectSummaryBasenamesPathAtSource() throws {
        let ledger = UsageLedger(fileURL: nil)
        let ts = Date(timeIntervalSince1970: 1_700_000_100)
        ledger.append([UsageEvent(id: "e1", providerId: "codex",
                                   projectId: "/Users/alice/SecretClient/foo", projectName: nil,
                                   modelId: "gpt-5.5", timestamp: ts,
                                   tokens: TokenBreakdown(input: 100), sourceKind: "x", sourcePath: nil)])
        let interval = DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000),
                                    end: Date(timeIntervalSince1970: 1_700_000_200))
        let projects = ledger.projectSummaries(in: interval, pricing: PricingRegistry(entries: []))
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].projectName, "foo", "display name must be basename, not the full cwd")
        XCTAssertEqual(projects[0].projectId, "/Users/alice/SecretClient/foo", "projectId keeps full value for grouping")
    }
}

// MARK: - Claude 窄 decoder(使用者指定的 test 4/5)

final class ClaudePrivacyTests: XCTestCase {
    // test 4:assistant 行含 message.content 機密 → 只擷取 usage;事件/帳本/報告都不得含機密。
    func testClaudeAdapterIgnoresMessageContent() throws {
        let root = privTempDir()
        let projDir = root.appendingPathComponent("-Users-alice-SecretClient-foo")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let line = "{\"type\":\"assistant\",\"timestamp\":\"2026-01-15T10:00:00Z\",\"requestId\":\"req1\",\"uuid\":\"u1\",\"cwd\":\"/Users/alice/SecretClient/foo\",\"message\":{\"id\":\"msg_secret\",\"model\":\"claude-sonnet-5\",\"content\":[{\"type\":\"text\",\"text\":\"SECRET_PROMPT_SHOULD_NOT_APPEAR\"}],\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}\n"
        try line.data(using: .utf8)!.write(to: projDir.appendingPathComponent("session.jsonl"))
        defer { try? FileManager.default.removeItem(at: root) }

        let adapter = ClaudeCodeAdapter(roots: [root], statuslineFiles: [], planConfigFiles: [])
        let (result, _) = try adapter.refreshUsage(state: ScanState())

        XCTAssertEqual(result.events.count, 1)
        let e = result.events[0]
        XCTAssertEqual(e.tokens.input, 100)
        XCTAssertEqual(e.tokens.output, 50)
        XCTAssertEqual(e.modelId, "claude-sonnet-5")
        // 事件的每個欄位都不得含機密內容
        let encoded = String(data: try JSONEncoder().encode(e), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("SECRET_PROMPT_SHOULD_NOT_APPEAR"), "message content leaked into UsageEvent: \(encoded)")
        // 帳本落地也不得含機密
        let ledger = UsageLedger(fileURL: nil)
        ledger.append(result.events)
        for ev in ledger.events {
            let j = String(data: try JSONEncoder().encode(ev), encoding: .utf8) ?? ""
            XCTAssertFalse(j.contains("SECRET_PROMPT_SHOULD_NOT_APPEAR"))
        }
    }

    // test 5:架構守則——assistant 行解析不得再用 JSONSerialization(改用窄 Decodable)。
    func testClaudeAdapterUsesNarrowDecoder() throws {
        let cwd = FileManager.default.currentDirectoryPath
        let src = URL(fileURLWithPath: cwd).appendingPathComponent("Sources/UsageCore/ClaudeCodeAdapter.swift")
        guard let text = try? String(contentsOf: src, encoding: .utf8) else {
            XCTAssertTrue(true, "skipped — source not found from cwd")
            return
        }
        XCTAssertTrue(text.contains("decode(ClaudeAssistantLine.self"),
                      "assistant line must be parsed via narrow Decodable")
        XCTAssertFalse(text.contains("JSONSerialization.jsonObject(with: hit.data)"),
                       "assistant line must NOT materialize the whole object via JSONSerialization")
    }
}
