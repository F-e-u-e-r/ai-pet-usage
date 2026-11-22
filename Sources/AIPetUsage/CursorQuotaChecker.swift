import Foundation
import Observation
import UsageCore

/// Cursor IDE monthly plan usage (opt-in). Bearer file → `state.vscdb` plaintext only — no Keychain in this app.
/// then calls `GetCurrentPeriodUsage` on api2.cursor.sh.
@MainActor
@Observable
final class CursorQuotaChecker {
    struct Status: Equatable {
        var snapshot: CursorQuotaSnapshot?
        var lastAttemptAt: Date?
        var lastOutcome: CursorQuotaOutcome?
        var health: SourceHealth = .ok
    }

    private(set) var status = Status()

    private var enabled = false
    private var bearerFilePath: String?
    private var gate = OpenRouterFetchGate()
    private var loopTask: Task<Void, Never>?
    private var manualFetchTask: Task<Void, Never>?
    private var machine = SourceHealthMachine.State()
    private var rateLimitedUntil: Date?
    private static let pollInterval: TimeInterval = 15 * 60

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config, delegate: CursorRedirectBlocker(), delegateQueue: nil)
    }()

    func setBearerFilePath(_ path: String?) {
        let t = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        bearerFilePath = (t?.isEmpty == false) ? t : nil
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
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
            status = Status()
            machine = SourceHealthMachine.State()
            rateLimitedUntil = nil
        }
    }

    func refreshNow() {
        guard enabled, let token = gate.tryBegin() else { return }
        manualFetchTask = Task { await self.fetchNow(claimed: token) }
    }

    func dataSourceStatus(now: Date = Date()) -> DataSourceStatus {
        let notLoggedIn = { () -> Bool in
            if case .noKey = status.lastOutcome { return true }
            return false
        }()
        let presence: SourcePresence = enabled
            ? (notLoggedIn ? .unavailable(.notLoggedIn) : .active)
            : .disabled
        let window = Self.pollInterval
        let lastOk = status.snapshot?.fetchedAt
        let stale = Freshness.assessObservation(lastObservedOk: lastOk, window: window,
                                                currentlyStale: false, now: now)
        let health = HealthDisplay.effective(machine: machine.health, isStale: stale.isStale)
        return DataSourceStatus(
            providerId: "cursor-ide", kind: .officialAPI,
            presence: presence, health: health,
            lastObservedOk: lastOk, lastAttemptAt: status.lastAttemptAt,
            newestDataAt: lastOk,
            attemptCount: status.lastAttemptAt == nil ? 0 : 1,
            provenanceNote: stale.note,
            recoveryAction: HealthDisplay.recovery(
                for: health, presence: presence,
                cli: "Paste a dashboard JWT into the bearer file (Settings path or default), or set CURSOR_ACCESS_TOKEN"))
    }

    private func fetchNow(claimed: Int? = nil) async {
        let token: Int
        if let claimed {
            token = claimed
        } else {
            guard enabled, let t = gate.tryBegin() else { return }
            token = t
        }
        defer { gate.end(token) }
        guard enabled, gate.shouldCommit(token), !Task.isCancelled else { return }
        if let until = rateLimitedUntil, Date() < until { return }

        let path = bearerFilePath
        let key = await Task.detached(priority: .utility) {
            CursorSessionToken.loadAccessToken(bearerFilePath: path)
        }.value
        guard enabled, gate.shouldCommit(token), !Task.isCancelled else { return }

        let attemptAt = Date()
        let outcome: CursorQuotaOutcome?
        if let key {
            outcome = await performFetch(key: key)
        } else {
            outcome = .noKey
        }

        guard let outcome, !Task.isCancelled, enabled, gate.shouldCommit(token) else { return }
        machine = SourceHealthMachine.step(machine, outcome.observationEvent)
        if case .rateLimited(let ra) = outcome {
            if let ra, ra.isFinite, ra > 0 {
                rateLimitedUntil = Date().addingTimeInterval(min(ra, 4 * 3600))
            } else {
                rateLimitedUntil = Date().addingTimeInterval(Self.pollInterval)
            }
        } else {
            rateLimitedUntil = nil
        }

        var next = status
        next.lastAttemptAt = attemptAt
        next.lastOutcome = outcome
        next.health = machine.health
        switch outcome {
        case .success(let snap):
            next.snapshot = snap
        case .keyRejected, .noKey:
            // No JWT / expired bearer: must not keep showing last official % (OpenRouter credits uses the same rule).
            next.snapshot = nil
        case .noUsageData:
            next.snapshot = nil
        case .schemaBreaking:
            next.snapshot = nil
        case .rateLimited, .invalidBody, .endpointGone, .serverError, .badReply, .networkError:
            break
        }
        status = next
    }

    private func performFetch(key: String) async -> CursorQuotaOutcome? {
        let version = AppVersionInfo.current.displayVersion ?? "dev"
        let request = CursorQuotaEngine.request(token: key, appVersion: version)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  CursorQuotaEngine.isTrustedResponse(url: http.url) else {
                bytes.task.cancel()
                return .badReply
            }
            if http.statusCode != 200 {
                bytes.task.cancel()
                var outcome = CursorQuotaEngine.parseResponse(statusCode: http.statusCode, data: Data(), now: Date())
                if case .rateLimited = outcome {
                    let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    outcome = .rateLimited(retryAfterSeconds: ra)
                }
                return outcome
            }
            var data = Data()
            data.reserveCapacity(2048)
            for try await byte in bytes {
                data.append(byte)
                if data.count > CursorQuotaEngine.maxResponseBytes {
                    bytes.task.cancel()
                    return .badReply
                }
            }
            var outcome = CursorQuotaEngine.parseResponse(statusCode: http.statusCode, data: data, now: Date())
            if case .rateLimited = outcome {
                let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                outcome = .rateLimited(retryAfterSeconds: ra)
            }
            return outcome
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return Task.isCancelled ? nil : .networkError
        } catch {
            return Task.isCancelled ? nil : .networkError
        }
    }
}

private final class CursorRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}