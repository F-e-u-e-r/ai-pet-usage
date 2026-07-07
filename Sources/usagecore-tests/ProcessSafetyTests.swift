import Foundation
import UsageCore

// MARK: - 跨行程安全(code review findings 的回歸測試)

final class FileLockTests: XCTestCase {
    func testExclusiveAcquireAndRelease() {
        let url = makeTempDir().appendingPathComponent("test.lock")
        let a = FileLock(url: url)
        let b = FileLock(url: url) // 不同的檔案描述符 → flock 互斥可在同行程內驗證

        XCTAssertTrue(a.acquire(timeout: 1))
        XCTAssertFalse(b.acquire(timeout: 0.2), "已被持有的鎖不可再取得")
        a.release()
        XCTAssertTrue(b.acquire(timeout: 1), "釋放後應可取得")
        b.release()
    }
}

final class LedgerCrossProcessTests: XCTestCase {
    func event(_ id: String, _ ts: String) -> UsageEvent {
        UsageEvent(id: id, providerId: "codex", timestamp: date(ts),
                   tokens: TokenBreakdown(input: 100), sourceKind: "test")
    }

    func testReloadIfChangedConvergesAndDedupes() {
        let file = makeTempDir().appendingPathComponent("ledger.jsonl")
        let a = UsageLedger(fileURL: file) // 模擬 app
        let b = UsageLedger(fileURL: file) // 模擬 CLI(獨立的記憶體狀態)

        a.append([event("e1", "2026-01-15T10:00:00Z")])
        XCTAssertEqual(b.events.count, 0, "b 尚未重載")

        b.reloadIfChanged()
        XCTAssertEqual(b.events.count, 1, "重載後收斂到磁碟狀態")

        // b 再附加同一事件 → 去重,不重複計費
        XCTAssertEqual(b.append([event("e1", "2026-01-15T10:00:00Z")]), 0)
        // b 附加新事件後,a 重載也收斂且無重複
        b.append([event("e2", "2026-01-15T11:00:00Z")])
        a.reloadIfChanged()
        XCTAssertEqual(a.events.map(\.id), ["e1", "e2"])

        // 未變更時 reloadIfChanged 為 no-op(events 參照不重建的行為不易直接驗證,驗證數量即可)
        a.reloadIfChanged()
        XCTAssertEqual(a.events.count, 2)
    }

    func testAppendAfterPartialFinalLinePreservesNewEventOnReload() throws {
        let file = makeTempDir().appendingPathComponent("ledger.jsonl")
        let encoder = AtomicJSON.encoder()
        let valid = event("valid-before-partial", "2026-01-15T10:00:00Z")
        let appended = event("new-after-partial", "2026-01-15T11:00:00Z")

        var seed = Data()
        seed.append(try encoder.encode(valid))
        seed.append(0x0A)
        seed.append(Data(#"{"id":"half-written-event""#.utf8))
        try seed.write(to: file)

        let ledger = UsageLedger(fileURL: file)
        XCTAssertEqual(ledger.events.map(\.id), ["valid-before-partial"])
        XCTAssertEqual(ledger.append([appended]), 1)

        let reloaded = UsageLedger(fileURL: file)
        XCTAssertTrue(reloaded.events.contains { $0.id == appended.id },
                      "new append must not be concatenated onto a stale half-line")
    }
}

final class SharedSettingsTests: XCTestCase {
    func testCLIReadsGUISettingsFile() throws {
        let dir = makeTempDir()
        // 模擬 GUI 寫入的 settings.json(含 core 欄位與其他 app 欄位)
        struct FakeAppSettings: Codable {
            var appMode = "monitorOnly"
            var petSize = 96.0
            var core: CoreSettings
        }
        var core = CoreSettings()
        core.claudeFiveHourTokenBudget = 123_000
        core.warnThresholdPercent = 70
        core.enabledProviders = ["codex"]
        try AtomicJSON.write(FakeAppSettings(core: core), to: dir.appendingPathComponent("settings.json"))

        let loaded = CoreSettings.loadShared(dataDir: dir)
        XCTAssertEqual(loaded.claudeFiveHourTokenBudget, 123_000)
        XCTAssertEqual(loaded.warnThresholdPercent, 70)
        XCTAssertEqual(loaded.enabledProviders, ["codex"])

        // 檔案不存在 → 預設值
        let fallback = CoreSettings.loadShared(dataDir: makeTempDir())
        XCTAssertEqual(fallback.warnThresholdPercent, 80)
        XCTAssertNil(fallback.claudeFiveHourTokenBudget)
    }
}

final class CompactionLockTests: XCTestCase {
    func testInitIsReadOnlyAndCompactionRunsUnderRefresh() throws {
        let dataDir = makeTempDir()
        // 預先寫入一筆超過保留期的舊事件
        let old = UsageEvent(id: "old", providerId: "codex",
                             timestamp: Date().addingTimeInterval(-200 * 86400),
                             tokens: TokenBreakdown(input: 10), sourceKind: "test")
        let seed = UsageLedger(fileURL: dataDir.appendingPathComponent("ledger.jsonl"))
        seed.append([old])
        let sizeBefore = try FileManager.default.attributesOfItem(
            atPath: dataDir.appendingPathComponent("ledger.jsonl").path)[.size] as! Int64

        // init(以及唯讀的 dashboard())不得改寫帳本檔
        let coordinator = UsageCoordinator(dataDir: dataDir, settings: CoreSettings(),
                                           adapters: [CodexAdapter(roots: [makeTempDir()])])
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            _ = await coordinator.dashboard()
            let sizeAfterInit = try! FileManager.default.attributesOfItem(
                atPath: dataDir.appendingPathComponent("ledger.jsonl").path)[.size] as! Int64
            XCTAssertEqual(sizeAfterInit, sizeBefore, "init/dashboard 不得觸發壓縮寫檔")

            // refresh(持鎖)後,過期事件應被壓縮掉
            _ = await coordinator.refresh()
            let reloaded = UsageLedger(fileURL: dataDir.appendingPathComponent("ledger.jsonl"))
            XCTAssertTrue(reloaded.events.isEmpty, "保留期外的事件應在持鎖壓縮時移除")
            semaphore.signal()
        }
        semaphore.wait()
    }
}

final class RefreshLockTests: XCTestCase {
    func testRefreshSkipsWhenLockHeldByAnotherProcess() {
        let dataDir = makeTempDir()
        // 模擬另一行程持有資料鎖
        let foreignLock = FileLock(url: dataDir.appendingPathComponent("refresh.lock"))
        XCTAssertTrue(foreignLock.acquire(timeout: 1))

        let coordinator = UsageCoordinator(dataDir: dataDir, settings: CoreSettings(),
                                           adapters: [CodexAdapter(roots: [makeTempDir()])],
                                           refreshLockTimeout: 0.3)
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            // 鎖被他人持有 → 跳過寫入、回報 skipped 與資料品質註記
            let skipped = await coordinator.refresh()
            XCTAssertTrue(skipped.skipped)
            XCTAssertEqual(skipped.insertedEvents, 0)
            XCTAssertTrue(skipped.dashboard.dataQuality.contains { $0.contains("refresh skipped") })

            // 釋放後 → 正常執行
            foreignLock.release()
            let normal = await coordinator.refresh()
            XCTAssertFalse(normal.skipped)
            semaphore.signal()
        }
        semaphore.wait()
    }
}
