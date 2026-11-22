import Foundation
import Observation
import UsageCore

/// Colab compute-unit balance (opt-in). Spawns `colab usage`; OAuth stays inside the CLI.
@MainActor
@Observable
final class ColabCreditsChecker {
    private(set) var status = ColabCreditsStatus()

    /// Called after status changes so the menu widget snapshot can refresh.
    var onDidUpdate: (() -> Void)?

    private var enabled = false
    private var gate = OpenRouterFetchGate()
    private var loopTask: Task<Void, Never>?
    private var manualFetchTask: Task<Void, Never>?
    private static let pollInterval: TimeInterval = 15 * 60

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
            status = ColabCreditsStatus()
        }
    }

    func refreshNow() {
        guard enabled, let token = gate.tryBegin() else { return }
        manualFetchTask = Task { await self.fetchNow(claimed: token) }
    }

    func dataSourceStatus(now: Date = Date()) -> DataSourceStatus {
        let presence: SourcePresence
        if !enabled {
            presence = .disabled
        } else if ColabCreditsFetcher.resolveColabBinary() == nil {
            presence = .unavailable(.notInstalled)
        } else if status.lastOutcome == .notLoggedIn || status.lastOutcome == .authFailed {
            presence = .unavailable(.notLoggedIn)
        } else {
            presence = .active
        }
        let window = Self.pollInterval
        let lastOk = status.snapshot?.fetchedAt
        let stale = Freshness.assessObservation(lastObservedOk: lastOk, window: window,
                                                currentlyStale: false, now: now)
        let health: SourceHealth = {
            guard enabled, presence == .active else { return stale.isStale ? .stale : .ok }
            switch status.lastOutcome {
            case .none: return status.snapshot == nil ? .ok : .ok
            case .success: return stale.isStale ? .stale : .ok
            case .timedOut, .networkError, .badReply: return .transientError
            default: return stale.isStale ? .stale : .ok
            }
        }()
        return DataSourceStatus(
            providerId: "colab", kind: .officialAPI,
            presence: presence, health: health,
            lastObservedOk: lastOk, lastAttemptAt: status.lastAttemptAt,
            newestDataAt: lastOk,
            attemptCount: status.lastAttemptAt == nil ? 0 : 1,
            provenanceNote: stale.note,
            recoveryAction: HealthDisplay.recovery(for: health, presence: presence, cli: "colab"))
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
        let attemptAt = Date()
        let outcome = await Task.detached(priority: .utility) {
            ColabCreditsFetcher.fetch(now: attemptAt)
        }.value
        guard !Task.isCancelled, enabled, gate.shouldCommit(token) else { return }
        var next = status
        next.lastAttemptAt = attemptAt
        next.lastOutcome = outcome
        switch outcome {
        case .success(let snap):
            next.snapshot = snap
        case .notLoggedIn, .authFailed, .cliMissing:
            next.snapshot = nil
        case .badReply, .timedOut, .networkError:
            break
        }
        status = next
        onDidUpdate?()
    }
}