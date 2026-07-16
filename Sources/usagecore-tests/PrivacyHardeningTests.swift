import Foundation
import UsageCore

// PR A — privacy hardening:HTML sink 端 redaction + Claude 窄 decoder。

private func privTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("aipet-priv-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeReport(projects: [ProjectSummary], dataQuality: [String],
                        models: [ModelUsageSummary] = [], pricingRows: [ModelPrice] = []) -> String {
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
        models: models,
        buckets: [],
        pricingRows: pricingRows,
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

    // codex SEV1 round-2(F4):覆寫檔的 source/effectiveFrom 與損壞日誌的 modelId/topModel
    // 可能帶絕對路徑 → 報告 sink 防護(basename / 固定字樣),合法值原樣。
    func testReportScrubsPathShapedModelIdAndPricingSource() throws {
        var proj = project(id: "/tmp/p", name: "demo")
        proj.topModel = "/Users/alice/SecretClient/model.bin"
        let models = [ModelUsageSummary(providerId: "codex", modelId: "/Users/alice/SecretClient/model.bin",
                                        tokens: TokenBreakdown(input: 100), cost: .zero),
                      ModelUsageSummary(providerId: "codex", modelId: "anthropic/claude-x",
                                        tokens: TokenBreakdown(input: 50), cost: .zero)]
        let prices = [ModelPrice(providerId: "codex", modelId: "/Users/alice/SecretClient/model.bin",
                                 displayName: "x", inputPerMillion: 1, outputPerMillion: 2,
                                 effectiveFrom: "from /Users/alice/SecretClient/prices.txt",
                                 source: "/Users/alice/SecretClient/prices.txt", userOverride: true),
                      ModelPrice(providerId: "codex", modelId: "anthropic/claude-x",
                                 displayName: "y", inputPerMillion: 1, outputPerMillion: 2,
                                 effectiveFrom: "2026-01-01",
                                 source: "anthropic.com/pricing built-in snapshot")]
        let html = makeReport(projects: [proj], dataQuality: [], models: models, pricingRows: prices)
        XCTAssertFalse(html.contains("/Users/"), "絕對路徑不得出現在報告")
        XCTAssertFalse(html.contains("SecretClient"))
        XCTAssertTrue(html.contains("model.bin"), "basename 保留模型身分")
        XCTAssertTrue(html.contains("custom (path redacted)"))
        XCTAssertTrue(html.contains("anthropic/claude-x"), "vendor/model 相對形不得誤傷")
        XCTAssertTrue(html.contains("anthropic.com/pricing built-in snapshot"), "合法標籤原樣")
    }
    // grok S2-3:來源端(UsageLedger.projectSummaries)缺 projectName 時,顯示名 basename 化,
    // 而非把完整 cwd 當顯示名 → UI 與 HTML 皆消費此淨化值。
    // codex SEV1 round-2(F5):refresh error 的 err 段是任意原文,可能內嵌其他樣板關鍵詞;
    // 「refresh error」必須最先判,且 unparsable count 只認緊鄰位置,不掃全字串。
    func testRefreshErrorEmbeddingUnparsableNotMisclassified() throws {
        let out = PrivacyRedaction.safeDataQuality(
            "codex: refresh error — unparsable line at /Users/alice/client-88421/log")
        XCTAssertEqual(out, "codex: refresh error")
        XCTAssertFalse(out.contains("88421"), "路徑衍生數字不得回顯")
        XCTAssertFalse(out.contains("/Users"))
    }

    func testUnparsableCountIsPositional() throws {
        XCTAssertEqual(PrivacyRedaction.safeDataQuality("codex: 12 unparsable line(s) skipped on last scan"),
                       "codex: 12 unparsable line(s) skipped on last scan")
        // 數字不在「unparsable line」緊前(如被嵌入的尾巴)→ 不得撿來當 count
        let out = PrivacyRedaction.safeDataQuality("codex: unparsable line junk 999 /Users/x")
        XCTAssertEqual(out, "codex: unparsable line(s) skipped on last scan")
        XCTAssertFalse(out.contains("999"))
    }

    // codex SEV1 round-2(F4):模型 ID / 定價標籤的絕對路徑防護(合法相對形不受影響)。
    func testDisplayModelIdAndSafeLabel() throws {
        XCTAssertEqual(PrivacyRedaction.displayModelId("claude-fable-5"), "claude-fable-5")
        XCTAssertEqual(PrivacyRedaction.displayModelId("anthropic/claude-x"), "anthropic/claude-x",
                       "vendor/model 相對形是合法 ID,不得誤傷")
        XCTAssertEqual(PrivacyRedaction.displayModelId("/Users/alice/SecretClient/model.bin"), "model.bin")
        XCTAssertEqual(PrivacyRedaction.displayModelId("C:\\Users\\alice\\m.bin"), "m.bin")
        XCTAssertEqual(PrivacyRedaction.safeLabel("anthropic.com/pricing built-in snapshot"),
                       "anthropic.com/pricing built-in snapshot", "合法內建標籤不受影響")
        XCTAssertEqual(PrivacyRedaction.safeLabel("from /Users/alice/SecretClient/prices.txt"),
                       "custom (path redacted)")
        XCTAssertEqual(PrivacyRedaction.safeLabel("~/notes/prices.md"), "custom (path redacted)")
    }

    // grok SEV2 / codex SEV1 round-3:`file://` scheme 與「嵌入式」絕對路徑也要攔
    //(token 前綴判定漏掉 `file:///Users/…`、`local (/Users/…)`、`x=/Users/…`)。
    func testAbsolutePathScrubCatchesSchemeAndEmbeddedForms() throws {
        XCTAssertEqual(PrivacyRedaction.displayModelId("file:///Users/alice/SecretClient/model.bin"),
                       "model.bin")
        XCTAssertEqual(PrivacyRedaction.safeLabel("file:///Users/alice/SecretClient/prices.json"),
                       "custom (path redacted)")
        XCTAssertEqual(PrivacyRedaction.safeLabel("local (/Users/alice/SecretClient/prices.json)"),
                       "custom (path redacted)")
        XCTAssertEqual(PrivacyRedaction.safeLabel("src=/Users/alice/SecretClient/p.txt"),
                       "custom (path redacted)")
        XCTAssertEqual(PrivacyRedaction.safeLabel("see C:\\clients\\secret\\p.txt"),
                       "custom (path redacted)")
        // 不得誤傷:web URL、孤立 ~(約數)、相對 vendor/model
        XCTAssertEqual(PrivacyRedaction.safeLabel("https://example.com/docs pricing page"),
                       "https://example.com/docs pricing page")
        XCTAssertEqual(PrivacyRedaction.safeLabel("approx ~5 min snapshot"),
                       "approx ~5 min snapshot")
        XCTAssertEqual(PrivacyRedaction.displayModelId("openrouter/anthropic/claude-x"),
                       "openrouter/anthropic/claude-x")
    }

    // grok SEV2 round-3:`~alice/…`(r3 收緊時回歸)與 `file://localhost/...`(主機形)也要攔。
    func testAbsolutePathScrubTildeUserAndFileHost() throws {
        XCTAssertEqual(PrivacyRedaction.safeLabel("~alice/SecretClient/prices.json"),
                       "custom (path redacted)")
        XCTAssertEqual(PrivacyRedaction.displayModelId("~alice/SecretClient/model.bin"), "model.bin")
        XCTAssertEqual(PrivacyRedaction.safeLabel("file://localhost/Users/alice/SecretClient/prices.json"),
                       "custom (path redacted)")
        XCTAssertEqual(PrivacyRedaction.displayModelId("file://localhost/Users/alice/SecretClient/model.bin"),
                       "model.bin")
        XCTAssertEqual(PrivacyRedaction.safeLabel("FILE://X/Users/alice/s.txt"),
                       "custom (path redacted)", "scheme 大小寫不影響")
        // ~5 仍不誤中(數字不是使用者名);孤立 ~ 無路徑主體也不誤中
        XCTAssertEqual(PrivacyRedaction.safeLabel("approx ~5 min"), "approx ~5 min")
        XCTAssertEqual(PrivacyRedaction.safeLabel("tilde ~ alone"), "tilde ~ alone")
    }

    // codex catch-up SEV1:URL 整串移除會把 query 裡挾帶的本機路徑一併吞掉 → 繞過。
    // 原字串必須先掃(= 分隔符抓到 ?local=/Users/…);一般 URL 仍不誤中。
    func testAbsolutePathScrubCompoundURLNotBypassed() throws {
        XCTAssertEqual(
            PrivacyRedaction.safeLabel("source=https://example.test/?local=/Users/alice/Secret/prices.json"),
            "custom (path redacted)")
        XCTAssertEqual(
            PrivacyRedaction.displayModelId("https://x.test/?m=/Users/alice/Secret/model.bin"),
            "model.bin")
        // 一般 URL(無挾帶路徑)仍不誤中
        XCTAssertEqual(PrivacyRedaction.safeLabel("see https://example.com/docs/prices"),
                       "see https://example.com/docs/prices")
    }

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
    // 以 #filePath 定位原始碼(cwd 無關),讀不到 → 測試**失敗**而非默默略過(fail-closed;
    // gpt plan-review SEV3:vacuous pass 會讓守則測試在 harness cwd 改變時形同虛設)。
    func testClaudeAdapterUsesNarrowDecoder() throws {
        let text = try String(contentsOf: adapterSource("ClaudeCodeAdapter.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("decode(ClaudeAssistantLine.self"),
                      "assistant line must be parsed via narrow Decodable")
        XCTAssertFalse(text.contains("JSONSerialization.jsonObject(with: hit.data)"),
                       "assistant line must NOT materialize the whole object via JSONSerialization")
    }
}

/// 以測試檔自身位置(#filePath)解析 UsageCore 原始碼路徑 —— 與 harness cwd 無關。
private func adapterSource(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)              // …/Sources/usagecore-tests/PrivacyHardeningTests.swift
        .deletingLastPathComponent()             // …/Sources/usagecore-tests
        .deletingLastPathComponent()             // …/Sources
        .appendingPathComponent("UsageCore").appendingPathComponent(name)
}

// MARK: - Codex 窄 decoder(Phase 2 item 1:最後一個 content-bearing 全物化解析)

final class CodexPrivacyTests: XCTestCase {
    private func writeRollout(_ lines: [String]) throws -> URL {
        let root = privTempDir()
        let dir = root.appendingPathComponent("2026/01/15")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").appending("\n").data(using: .utf8)!
            .write(to: dir.appendingPathComponent("rollout-2026-01-15T10-00-00-test.jsonl"))
        return root
    }

    // 通過 quickFilter 的行帶訊息內容/机密 → 只擷取用量;事件與帳本不得含机密。
    func testCodexAdapterIgnoresMessageContent() throws {
        let root = try writeRollout([
            #"{"timestamp":"2026-01-15T10:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/Users/alice/SecretClient/foo","base_instructions":{"text":"SECRET_INSTRUCTIONS_SHOULD_NOT_APPEAR"}}}"#,
            // response_item 含 "token_count" 字樣 → 通過 quickFilter,但窄 decoder 不物化 content
            #"{"timestamp":"2026-01-15T10:01:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"SECRET_OUTPUT token_count SHOULD_NOT_APPEAR /Users/alice/SecretClient"}]}}"#,
            #"{"timestamp":"2026-01-15T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":100,"total_tokens":1100}},"rate_limits":{"primary":{"used_percent":54.0,"window_minutes":300,"resets_at":1768475700},"secondary":null,"plan_type":"plus"}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let adapter = CodexAdapter(roots: [root])
        let (result, _) = try adapter.refreshUsage(state: ScanState())
        XCTAssertEqual(result.events.count, 1)
        let e = result.events[0]
        XCTAssertEqual(e.tokens.input, 800)      // 1000 − 200 cached
        XCTAssertEqual(e.tokens.cacheRead, 200)
        XCTAssertEqual(e.tokens.output, 100)
        XCTAssertEqual(e.projectName, "foo")
        let encoded = String(data: try JSONEncoder().encode(e), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("SECRET_"), "content leaked into UsageEvent: \(encoded)")
        XCTAssertEqual(result.rateLimits.count, 1)
        XCTAssertEqual(result.rateLimits[0].planType, "plus")
        XCTAssertEqual(result.rateLimits[0].primary?.usedPercent, 54.0)
    }

    // 架構守則:rollout 行解析不得用 JSONSerialization(窄 Decodable);fail-closed 定位原始碼。
    func testCodexAdapterUsesNarrowDecoder() throws {
        let text = try String(contentsOf: adapterSource("CodexAdapter.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("decode(CodexLine.self"),
                      "rollout line must be parsed via narrow Decodable")
        XCTAssertFalse(text.contains("JSONSerialization.jsonObject"),
                       "rollout parsing must NOT materialize whole objects via JSONSerialization")
    }

    // decoder 嚴格度 pin(grok plan P5):整數 used_percent 解進 Double、外層 timestamp 壞 →
    // payload 後援、usage 型別錯 → parseError+跳行(不默默 0)、secondary null 容忍。
    func testCodexDecoderStrictnessAndFallbacks() throws {
        let root = try writeRollout([
            // 整數 used_percent(77)+ null secondary + 外層 timestamp 無效 → payload.timestamp 後援
            #"{"timestamp":"not-a-date","type":"event_msg","payload":{"type":"token_count","timestamp":"2026-01-15T11:00:00.000Z","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":50,"total_tokens":550}},"rate_limits":{"primary":{"used_percent":77,"window_minutes":300,"resets_at":1768475700},"secondary":null,"plan_type":"plus"}}}"#,
            // usage 整體型別錯(字串)→ 整行 decode 失敗 → parseErrors+1、不產生事件
            #"{"timestamp":"2026-01-15T11:05:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":"corrupted"},"rate_limits":{"primary":{"used_percent":80.0,"window_minutes":300,"resets_at":1768475700}}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let adapter = CodexAdapter(roots: [root])
        let (result, _) = try adapter.refreshUsage(state: ScanState())
        XCTAssertEqual(result.events.count, 1, "只有健康行產生事件")
        XCTAssertEqual(result.events[0].timestamp, ISO8601.parse("2026-01-15T11:00:00.000Z"),
                       "外層 timestamp 壞 → payload.timestamp 後援")
        XCTAssertEqual(result.rateLimits.count, 1, "壞行的 rate_limits 不得部分擷取")
        XCTAssertEqual(result.rateLimits[0].primary?.usedPercent, 77.0, "JSON 整數解進 Double")
        XCTAssertEqual(result.parseErrors, 1, "型別錯的行計入 parseErrors")
    }
}

// MARK: - StatusRenderer / RootDisclosure(Phase 2 item 2:status/sources 的 sink 政策)

final class StatusRendererTests: XCTestCase {
    private func poisonedDashboard() -> DashboardState {
        let now = Date(timeIntervalSince1970: 1_768_000_000)
        let snap = UsageSnapshot(providerId: "codex", displayName: "Codex\u{1B}[31m",
                                 status: .error, sourceDescription: "t",
                                 errorMessage: "read failed at /Users/alice/SecretClient/x.jsonl SENTINEL_ERR")
        let limit = ProviderLimitState(
            providerId: "codex",
            fiveHour: LimitWindowState(usedPercent: 50, windowMinutes: 300, confidence: .high),
            weekly: LimitWindowState(usedPercent: 20, windowMinutes: 10080, confidence: .high),
            burnRateTokensPerHour: 1000, lastEventAt: now,
            warning: .ok, planType: "/Users/alice/SecretClient\u{1B}]0;pwn\u{07} plan")
        let proj = ProjectSummary(projectId: "/Users/alice/SecretClient/proj",
                                  projectName: "/Users/alice/SecretClient/proj\nINJECTED",
                                  tokens: TokenBreakdown(input: 100), cost: .zero,
                                  providers: ["codex"], topModel: nil, lastActive: nil, shareOfPeriod: 1)
        return DashboardState(generatedAt: now, snapshots: [snap], limitStates: [limit],
                              todayTotals: TokenBreakdown(input: 100), todayCost: .zero, todayByProvider: [],
                              burnRateTokensPerHour: 1000, burnCostPerHour: 0, hourly: [],
                              topProjects: [proj], models: [],
                              dataQuality: ["codex: refresh error — cause at /Users/alice/SecretClient/log SENTINEL_DQ"],
                              lastRefreshAt: now)
    }

    // 預設輸出:路徑/錯誤原文/控制字元一律不得出現;--full 出原文但仍無控制字元。
    func testStatusDefaultSuppressesPathsErrorsAndControls() throws {
        let out = StatusRenderer.statusText(dashboard: poisonedDashboard(), headline: "cached", full: false)
        XCTAssertFalse(out.contains("/Users/"), out)
        XCTAssertFalse(out.contains("SecretClient"), out)
        XCTAssertFalse(out.contains("SENTINEL_ERR"), "錯誤原文不得出現在預設輸出")
        XCTAssertFalse(out.contains("SENTINEL_DQ"), "dataQuality 原文不得出現在預設輸出")
        XCTAssertFalse(out.contains("\u{1B}"), "控制字元必須剝除")
        XCTAssertFalse(out.contains("INJECTED\n") || out.contains("\nINJECTED"),
                       "換行注入不得偽造輸出行:\(out)")
        XCTAssertTrue(out.contains("provider refresh failed (run with --full"), out)
        XCTAssertTrue(out.contains("refresh error"), "dataQuality 走 safeDataQuality 樣板")
        XCTAssertTrue(out.contains("proj"), "專案 basename 保留")
    }

    func testStatusFullPassesRawButStripsControls() throws {
        let out = StatusRenderer.statusText(dashboard: poisonedDashboard(), headline: "cached", full: true)
        XCTAssertTrue(out.contains("SENTINEL_ERR"), "--full 應印錯誤原文")
        XCTAssertTrue(out.contains("SENTINEL_DQ"), "--full 應印 dataQuality 原文")
        XCTAssertTrue(out.contains("/Users/alice/SecretClient"), "--full 應印原始路徑")
        XCTAssertFalse(out.contains("\u{1B}"), "--full 仍須剝控制字元(終端安全)")
    }

    // planType 是 provider 可控自由字串:路徑形收斂 + 上限;正常方案名原樣。
    func testStatusPlanLabelPolicy() throws {
        let out = StatusRenderer.statusText(dashboard: poisonedDashboard(), headline: "h", full: false)
        XCTAssertTrue(out.contains("plan: custom (path redacted)"), out)
        var dash = poisonedDashboard()
        dash.limitStates[0].planType = "Max 20x"
        let ok = StatusRenderer.statusText(dashboard: dash, headline: "h", full: false)
        XCTAssertTrue(ok.contains("plan: Max 20x"), ok)
    }

    func testSourcesDisclosureRendering() throws {
        func info(_ a: ProviderAvailability)
            -> (providerId: String, displayName: String, availability: ProviderAvailability,
                dataSources: String, permissions: String) {
            ("codex", "Codex", a, "docs", "read-only")
        }
        let builtinFound = StatusRenderer.sourcesText(
            infos: [info(ProviderAvailability(available: true, detail: "found /Users/alice/.codex/sessions",
                                              disclosure: .builtin(label: "~/.codex/sessions")))], full: false)
        XCTAssertTrue(builtinFound.contains("found ~/.codex/sessions"), builtinFound)
        XCTAssertFalse(builtinFound.contains("/Users/"), "預設不印原始路徑:\(builtinFound)")

        let customFound = StatusRenderer.sourcesText(
            infos: [info(ProviderAvailability(available: true,
                                              detail: "found /Users/alice/Clients/SecretAcquisition/codex/sessions"))],
            full: false)
        XCTAssertTrue(customFound.contains("custom root (found; details hidden)"), customFound)
        XCTAssertFalse(customFound.contains("SecretAcquisition"), customFound)

        let customFull = StatusRenderer.sourcesText(
            infos: [info(ProviderAvailability(available: true,
                                              detail: "found /Users/alice/Clients/SecretAcquisition/codex/sessions"))],
            full: true)
        XCTAssertTrue(customFull.contains("SecretAcquisition"), "--full 應印 detail 原文")
    }

    // RootDisclosure.classify:偵測到的根對照內建候選(不是 env 有沒有設)。
    func testRootDisclosureClassify() throws {
        let home = URL(fileURLWithPath: "/Users/alice")
        let builtin = [(url: home.appendingPathComponent(".claude/projects"), label: "~/.claude/projects"),
                       (url: home.appendingPathComponent(".config/claude/projects"), label: "~/.config/claude/projects")]
        // (a) 只有次要內建存在 → 吻合的次要標籤(不得寫死主要)
        XCTAssertEqual(RootDisclosure.classify(selectedRoot: home.appendingPathComponent(".config/claude/projects"),
                                               candidates: builtin.map(\.url), builtin: builtin),
                       .builtin(label: "~/.config/claude/projects"))
        // (b) env 設了但指向內建位置(等價路徑,含 ../ 正規化)→ 仍是 builtin
        XCTAssertEqual(RootDisclosure.classify(
                           selectedRoot: URL(fileURLWithPath: "/Users/alice/.claude/../.claude/projects"),
                           candidates: builtin.map(\.url), builtin: builtin),
                       .builtin(label: "~/.claude/projects"))
        // (c) 覆寫到非內建 —— 家內或家外一律 custom(/Users/alice2 前綴碰撞也是 custom)
        for custom in ["/Users/alice/Clients/Secret/claude/projects", "/srv/claude/projects",
                       "/Users/alice2/.claude/projects"] {
            XCTAssertEqual(RootDisclosure.classify(selectedRoot: URL(fileURLWithPath: custom),
                                                   candidates: builtin.map(\.url) + [URL(fileURLWithPath: custom)],
                                                   builtin: builtin),
                           .custom, custom)
        }
        // 全新安裝:無選定根、候選全屬內建 → 主要內建標籤(gpt catch-up SEV2 的表達力案例)
        XCTAssertEqual(RootDisclosure.classify(selectedRoot: nil,
                                               candidates: builtin.map(\.url), builtin: builtin),
                       .builtin(label: "~/.claude/projects"))
        // 無選定根但候選含非內建 → custom(fail-closed)
        XCTAssertEqual(RootDisclosure.classify(selectedRoot: nil,
                                               candidates: [URL(fileURLWithPath: "/srv/x")], builtin: builtin),
                       .custom)
    }

    // adapter 層:注入自訂 roots → detectAvailability 揭露為 custom(detail 保留原文供 --full)。
    func testAdapterDisclosureCustomRoots() throws {
        let tmp = privTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = CodexAdapter(roots: [tmp]).detectAvailability()
        XCTAssertEqual(a.disclosure, .custom)
        XCTAssertTrue(a.available)
        XCTAssertTrue(a.detail.contains(tmp.lastPathComponent), "detail 保留原文供 --full")
    }
}
