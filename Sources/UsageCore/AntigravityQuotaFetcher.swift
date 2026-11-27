import Foundation

/// Official quota buckets from `agy -p "/usage" --output-format json` (Antigravity CLI).
/// Not persisted on disk by the CLI — fetched by spawning agy on refresh when enabled.
public struct AntigravityQuotaSnapshot: Codable, Sendable, Equatable {
    public var fetchedAt: Date
    public var groups: [AntigravityQuotaGroup]

    public init(fetchedAt: Date, groups: [AntigravityQuotaGroup]) {
        self.fetchedAt = fetchedAt
        self.groups = groups
    }

    /// Strip agy’s “no reset scheduled” sentinel from every bucket (for display + persistence).
    public func normalizingEpochResetTimes() -> AntigravityQuotaSnapshot {
        AntigravityQuotaSnapshot(
            fetchedAt: fetchedAt,
            groups: groups.map { group in
                AntigravityQuotaGroup(
                    name: group.name,
                    buckets: group.buckets.map { bucket in
                        AntigravityQuotaBucket(
                            id: bucket.id,
                            label: bucket.label,
                            windowMinutes: bucket.windowMinutes,
                            usedPercent: bucket.usedPercent,
                            remainingPercent: bucket.remainingPercent,
                            resetsAt: AntigravityQuotaFetcher.normalizedResetTime(bucket.resetsAt))
                    })
            })
    }
}

public struct AntigravityQuotaGroup: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var buckets: [AntigravityQuotaBucket]

    public var id: String { name }

    public init(name: String, buckets: [AntigravityQuotaBucket]) {
        self.name = name
        self.buckets = buckets
    }
}

public struct AntigravityQuotaBucket: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var windowMinutes: Int
    /// Consumed quota `(1 − remaining_fraction) × 100`.
    public var usedPercent: Double
    public var remainingPercent: Double
    public var resetsAt: Date?

    public init(id: String, label: String, windowMinutes: Int, usedPercent: Double,
                remainingPercent: Double, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }
}

public enum AntigravityQuotaFetcher {
    private struct UsageRoot: Decodable {
        struct Command: Decodable {
            struct Payload: Decodable {
                struct Group: Decodable {
                    struct Bucket: Decodable {
                        let id: String?
                        let name: String?
                        let window: String?
                        let remaining_fraction: Double?
                        let reset_time: String?
                    }
                    let name: String?
                    let buckets: [Bucket]?
                }
                let groups: [Group]?
            }
            let data: Payload?
        }
        let command: Command?
    }

    /// Spawn `agy` (or `executableURL`) with a bounded wait. Returns nil when binary missing or parse fails.
    public static func fetch(
        now: Date = Date(),
        executableURL: URL? = resolveAgyBinary(),
        run: ((URL) throws -> Data)? = nil
    ) -> AntigravityQuotaSnapshot? {
        guard let executableURL else { return nil }
        let runner = run ?? defaultRun
        guard let data = try? runner(executableURL),
              let root = try? JSONDecoder().decode(UsageRoot.self, from: data),
              let groupsIn = root.command?.data?.groups else { return nil }
        var groups: [AntigravityQuotaGroup] = []
        for g in groupsIn {
            guard let gname = g.name, !gname.isEmpty else { continue }
            var buckets: [AntigravityQuotaBucket] = []
            for b in g.buckets ?? [] {
                guard let bid = b.id, let label = b.name else { continue }
                guard let remaining = b.remaining_fraction else { continue }
                let remPct = min(100, max(0, remaining * 100))
                let used = min(100, max(0, 100 - remPct))
                // Unknown window (e.g. a new "24h" bucket): skip rather than mislabel it as the weekly quota.
                guard let windowMin = windowMinutes(b.window) else { continue }
                let resets = b.reset_time.flatMap { parseResetTime($0) }
                buckets.append(AntigravityQuotaBucket(id: bid, label: label, windowMinutes: windowMin,
                                                      usedPercent: used, remainingPercent: remPct,
                                                      resetsAt: resets))
            }
            if !buckets.isEmpty {
                groups.append(AntigravityQuotaGroup(name: gname, buckets: buckets))
            }
        }
        guard !groups.isEmpty else { return nil }
        return AntigravityQuotaSnapshot(fetchedAt: now, groups: groups).normalizingEpochResetTimes()
    }

    /// Primary 5h / weekly reading for limit engine: **Gemini Models** group (default agy routing).
    public static func geminiModelsRateLimit(from snapshot: AntigravityQuotaSnapshot,
                                             providerId: String = "antigravity") -> RateLimitReading? {
        guard let group = snapshot.groups.first(where: { $0.name == "Gemini Models" }) else { return nil }
        let five = group.buckets.first { $0.windowMinutes == 300 }
        let week = group.buckets.first { $0.windowMinutes == 10_080 }
        guard five != nil || week != nil else { return nil }
        func win(_ b: AntigravityQuotaBucket?) -> RateLimitWindowReading? {
            guard let b else { return nil }
            return RateLimitWindowReading(usedPercent: b.usedPercent, windowMinutes: b.windowMinutes,
                                          resetsAt: b.resetsAt)
        }
        return RateLimitReading(providerId: providerId, observedAt: snapshot.fetchedAt,
                                primary: win(five), secondary: win(week),
                                planType: nil, sourcePath: "agy:/usage")
    }

    public static func resolveAgyBinary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    /// agy emits `1970-01-01T00:00:00Z` when a bucket has no scheduled reset (common on Claude/GPT third-party pools).
    static func parseResetTime(_ raw: String) -> Date? {
        normalizedResetTime(ISO8601.parse(raw))
    }

    /// Epoch / absent reset sentinel — same rule on fresh fetch and on disk reload.
    public static func normalizedResetTime(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }

    private static func windowMinutes(_ window: String?) -> Int? {
        switch window?.lowercased() {
        case "5h", "five_hour", "five-hour": return 300
        case "weekly", "week", "7d": return 10_080
        default: return nil
        }
    }

    private static func defaultRun(executableURL: URL) throws -> Data {
        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = ["-p", "/usage", "--output-format", "json"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice   // never read; an undrained pipe would block the child
        // Drain stdout as it arrives (a child that fills the ~64 KB pipe buffer would block until killed),
        // event-driven so no thread is left blocked on a pipe a descendant keeps open.
        let collected = CollectedOutput()
        let exited = DispatchSemaphore(value: 0)
        let reader = out.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; collected.finish() } else { collected.append(chunk) }
        }
        proc.terminationHandler = { _ in exited.signal() }
        // Stop the handler on every exit path. No explicit close: a handler already running still reads the
        // handle, and `availableData` on a closed handle raises; the pipe closes when the last reference goes.
        defer { reader.readabilityHandler = nil }
        try proc.run()
        let deadline = DispatchTime.now() + .seconds(20)
        if exited.wait(timeout: deadline) == .timedOut {
            proc.terminate()
            throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "agy /usage timed out"])
        }
        // Child exited: give the pipe a moment to reach EOF; a descendant holding it open must not stall us.
        _ = collected.eof.wait(timeout: min(deadline, DispatchTime.now() + .seconds(2)))
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "AntigravityQuotaFetcher", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "agy /usage exited \(proc.terminationStatus)"])
        }
        return collected.snapshot()
    }

    /// Filled from the pipe's readability handler; guarded by a lock.
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

public enum AntigravityQuotaStore {
    public static let fileName = "antigravity-quota.json"

    public static func url(dataDir: URL) -> URL {
        dataDir.appendingPathComponent(fileName)
    }

    public static func load(dataDir: URL) -> AntigravityQuotaSnapshot? {
        guard let raw = AtomicJSON.read(AntigravityQuotaSnapshot.self, from: url(dataDir: dataDir)) else {
            return nil
        }
        let snap = raw.normalizingEpochResetTimes()
        if snap != raw {
            try? AtomicJSON.write(snap, to: url(dataDir: dataDir))
        }
        return snap
    }

    public static func save(_ snapshot: AntigravityQuotaSnapshot?, dataDir: URL) {
        let file = url(dataDir: dataDir)
        if let snapshot {
            try? AtomicJSON.write(snapshot.normalizingEpochResetTimes(), to: file)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }
}