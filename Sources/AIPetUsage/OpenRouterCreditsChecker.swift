import Foundation
import Observation
import UsageCore

/// OpenRouter credits 監控的 GUI 接線層(opt-in,預設關;純邏輯在 UsageCore.OpenRouterCredits*)。
/// 邊界(docs/DATA_SOURCES.md「OpenRouter credits」;R1 雙審定案):
///   - 停用 ⇒ 不開檔、不排程、清空狀態、取消進行中請求、丟棄晚到回應(世代守衛)。
///   - key 於**每次抓取時**才從 opencode 的 auth.json 讀出(key 會輪替),只存在於
///     fetch 呼叫的區域範疇;GUI 忽略 OPENROUTER_API_KEY env。無 key ⇒ 零網路。
///   - 專用 ephemeral session:無磁碟快取、無 cookie、**拒絕所有 redirect**
///     (Authorization header 絕不跟著轉址走)。
///   - 錯誤一律映射到 UsageCore 的封閉詞彙;不 log request/response/key,
///     不使用 error.localizedDescription。
///   - 15 分鐘輪詢 + 啟用當下 + 面板手動 Refresh;**不**掛在 FSEvents 刷新風暴上。
@MainActor
@Observable
final class OpenRouterCreditsChecker {
    private(set) var status = OpenRouterCreditsStatus()

    private var enabled = false
    /// 單流 + 世代守衛的純決策核心(UsageCore.OpenRouterFetchGate,可測):
    /// 停用/重開 bump 世代並強制釋放佔用;晚到結果以 shouldCommit 丟棄。
    private var gate = OpenRouterFetchGate()
    private var loopTask: Task<Void, Never>?
    /// 手動 Refresh 的 unstructured Task:停用時一併取消(loop 內的 fetch 由
    /// loopTask 取消沿結構化併行傳遞;這條路徑需要自己記著)。
    private var manualFetchTask: Task<Void, Never>?
    private static let pollInterval: TimeInterval = 15 * 60

    /// 專用 session:ephemeral(記憶體 only)、無 cookie、不寫任何快取、拒絕 redirect。
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config, delegate: RedirectBlocker(), delegateQueue: nil)
    }()

    /// 設定開關的唯一入口(AppModel 於啟動與設定變更時呼叫)。冪等。
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        // bump = 世代 +1 並強制釋放單流佔用(R2 grok F2 / codex F1:否則停用→啟用的
        // 競態下,新 loop 的立即抓取會被還沒退場的舊 fetch 擋掉,第一筆餘額要等 15 分鐘)。
        // 舊 fetch 的晚寫由 shouldCommit 丟棄;其 end() 因不再持有佔用而不會誤清新 fetch。
        gate.bumpGeneration()
        loopTask?.cancel()
        loopTask = nil
        manualFetchTask?.cancel()
        manualFetchTask = nil
        if on {
            loopTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.fetchNow()
                    try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                }
            }
        } else {
            status = OpenRouterCreditsStatus()   // 清空:停用後 UI 不得殘留餘額
        }
    }

    /// 面板「Refresh Now」手動刷新(僅啟用時)。單流:進行中則跳過(**不**取消
    /// in-flight fetch —— R2 grok F1:取消會把 CancellationError 誤寫成
    /// 「can't reach OpenRouter」,還讓這次點擊實際上沒刷新)。
    /// gate 佔用在**此刻同步 claim**(R3 codex F1):若延到 task 執行時才 claim,
    /// 排隊中的舊 task 可在 off→on 之後搶佔新世代,讓新 loop 的立即抓取被擋、
    /// 空等 15 分鐘;同步 claim 也讓連點自然單流(第二點 tryBegin 即 nil)。
    func refreshNow() {
        guard enabled, let token = gate.tryBegin() else { return }
        manualFetchTask = Task { await self.fetchNow(claimed: token) }
    }

    // MARK: - 抓取

    /// `claimed`:呼叫端已同步取得的 gate token(手動刷新);nil = 自行 claim(輪詢 loop)。
    private func fetchNow(claimed: Int? = nil) async {
        let token: Int
        if let claimed {
            token = claimed
        } else {
            guard enabled, let t = gate.tryBegin() else { return }
            token = t
        }
        defer { gate.end(token) }
        // 排隊期間被停用/重開(世代不符)或已被取消 → key I/O 之前就退出。
        guard enabled, gate.shouldCommit(token), !Task.isCancelled else { return }
        let attemptAt = Date()

        // key 讀取移出 MainActor(R2 grok P3-7:同步檔案 I/O 不佔主執行緒)。
        let key = await Task.detached(priority: .utility) { Self.loadKey() }.value
        // 檔案讀取期間被停用/重開 → 這裡就停,**連請求都不發**(R2 codex F3)。
        guard enabled, gate.shouldCommit(token), !Task.isCancelled else { return }
        let outcome: OpenRouterCreditsOutcome?
        if let key {
            outcome = await performFetch(key: key)
        } else {
            outcome = .noKey
        }

        // 取消不是結果(R2 grok F1):被取消的 fetch 不得把 CancellationError
        // 寫成「can't reach」;世代守衛再擋停用/重開期間的晚寫。
        guard let outcome, !Task.isCancelled, enabled, gate.shouldCommit(token) else { return }
        var next = status
        next.lastAttemptAt = attemptAt
        next.lastOutcome = outcome
        switch outcome {
        case .success(let snap):
            next.snapshot = snap
        case .keyRejected, .noKey:
            // 帳號連結已斷:舊餘額不得再以「上次值」示人(R1 G3)。
            next.snapshot = nil
        case .serverError, .badReply, .networkError:
            break   // 保留舊快照;presentation 會標示失敗 + 年齡
        }
        status = next
    }

    /// 回傳 nil = fetch 被取消(不是結果,絕不寫入 status —— R2 grok F1)。
    private func performFetch(key: String) async -> OpenRouterCreditsOutcome? {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let request = OpenRouterCreditsEngine.request(key: key, appVersion: version)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  OpenRouterCreditsEngine.isTrustedResponse(url: http.url) else {
                bytes.task.cancel()
                return .badReply
            }
            // 於下載期即強制回應大小上限(R2 grok F5):超限立即斷線,
            // 不先整包緩衝(parseResponse 內的檢查保留作縱深防禦)。
            var data = Data()
            data.reserveCapacity(1024)
            for try await byte in bytes {
                data.append(byte)
                if data.count > OpenRouterCreditsEngine.maxResponseBytes {
                    bytes.task.cancel()
                    return .badReply
                }
            }
            return OpenRouterCreditsEngine.parseResponse(statusCode: http.statusCode, data: data, now: Date())
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            return Task.isCancelled ? nil : .networkError   // 錯誤內文刻意不保留(封閉詞彙)
        }
    }

    // MARK: - Key 定位(每次抓取時讀;不監看、不快取)

    /// opencode 資料目錄:尊重 XDG_DATA_HOME(opencode 在 macOS 也走 XDG;
    /// XDG 規範:**非絕對路徑必須忽略** —— R2 codex F3),否則 ~/.local/share/opencode。
    /// 僅此一檔;GUI 不讀 OPENROUTER_API_KEY env。
    nonisolated static func authFileURL() -> URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("opencode/auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
    }

    nonisolated private static func loadKey() -> String? {
        let url = authFileURL()
        // capped read(R2 codex F3):非 regular file 拒讀;以 FileHandle 讀「上限 + 1」
        // bytes 界定實際讀取量 —— stat-then-read 的競態(讀取瞬間檔案長大)無從繞過。
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: OpenRouterKeyParser.maxAuthFileBytes + 1),
              data.count <= OpenRouterKeyParser.maxAuthFileBytes else { return nil }
        return OpenRouterKeyParser.parse(data: data)   // 整檔 bytes 進、僅 openrouter 項被解碼
    }
}

/// session delegate:redirect 決策委派給 UsageCore 純函式(一律 nil = 拒絕)。
/// 分離的 nonisolated class —— delegate 回呼不在 MainActor。
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        OpenRouterCreditsEngine.redirectDecision()
    }
}
