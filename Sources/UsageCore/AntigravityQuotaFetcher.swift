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
                let windowMin = windowMinutes(b.window)
                let resets = b.reset_time.flatMap { ISO8601.parse($0) }
                buckets.append(AntigravityQuotaBucket(id: bid, label: label, windowMinutes: windowMin,
                                                      usedPercent: used, remainingPercent: remPct,
                                                      resetsAt: resets))
            }
            if !buckets.isEmpty {
                groups.append(AntigravityQuotaGroup(name: gname, buckets: buckets))
            }
        }
        guard !groups.isEmpty else { return nil }
        return AntigravityQuotaSnapshot(fetchedAt: now, groups: groups)
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

    private static func windowMinutes(_ window: String?) -> Int {
        switch window?.lowercased() {
        case "5h", "five_hour", "five-hour": return 300
        case "weekly", "week", "7d": return 10_080
        default: return 10_080
        }
    }

    private static func defaultRun(executableURL: URL) throws -> Data {
        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = ["-p", "/usage", "--output-format", "json"]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            proc.waitUntilExit()
            group.leave()
        }
        let deadline = DispatchTime.now() + .seconds(20)
        if group.wait(timeout: deadline) == .timedOut {
            proc.terminate()
            throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "agy /usage timed out"])
        }
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "AntigravityQuotaFetcher", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "agy /usage exited \(proc.terminationStatus)"])
        }
        return out.fileHandleForReading.readDataToEndOfFile()
    }
}

public enum AntigravityQuotaStore {
    public static let fileName = "antigravity-quota.json"

    public static func url(dataDir: URL) -> URL {
        dataDir.appendingPathComponent(fileName)
    }

    public static func load(dataDir: URL) -> AntigravityQuotaSnapshot? {
        AtomicJSON.read(AntigravityQuotaSnapshot.self, from: url(dataDir: dataDir))
    }

    public static func save(_ snapshot: AntigravityQuotaSnapshot?, dataDir: URL) {
        let file = url(dataDir: dataDir)
        if let snapshot {
            try? AtomicJSON.write(snapshot, to: file)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }
}