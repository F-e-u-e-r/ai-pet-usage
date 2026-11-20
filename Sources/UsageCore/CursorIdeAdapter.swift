import Foundation

/// Reads Cursor IDE agent structured logs under
/// `~/Library/Application Support/Cursor/logs/**/anysphere.cursor-always-local/Cursor Structured Logs*.log`.
/// Only lines with `Setting token details for client token ring` (per-round token totals as strings in metadata)
/// and `cursor_agent_exec.startup.workspace_paths` (workspace path list) are decoded. Message bodies,
/// chat store databases, and credentials are never read.
///
/// Token fields in the log are cumulative within a composer session; each event is the positive delta since
/// the previous reading in the same log file (regression resets the baseline with no negative event).
/// Cursor does not expose subscription usage-percent in these logs, so none is reported.
public struct CursorIdeAdapter: ProviderAdapter {
    public let providerId = "cursor-ide"
    public var reportedLimitCapability: ReportedLimitCapability { .notProvided }
    public var historyModel: ProviderHistoryModel { .rebuildableHistory }
    public let displayName = "Cursor"

    private let candidateRoots: [URL]

    public var roots: [URL] {
        candidateRoots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public init(logRoots: [URL]? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let logRoots {
            self.candidateRoots = logRoots
        } else if let custom = ProcessInfo.processInfo.environment["CURSOR_LOGS"],
                  !custom.isEmpty {
            self.candidateRoots = [URL(fileURLWithPath: custom, isDirectory: true)]
        } else {
            self.candidateRoots = [
                home.appendingPathComponent("Library/Application Support/Cursor/logs", isDirectory: true),
            ]
        }
    }

    static func builtinRoots() -> [(url: URL, label: String)] {
        [(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/logs"),
          "~/Library/Application Support/Cursor/logs")]
    }

    public func detectAvailability() -> ProviderAvailability {
        let disclosure = RootDisclosure.classify(selectedRoot: roots.first,
                                                 candidates: candidateRoots,
                                                 builtin: Self.builtinRoots())
        guard let root = roots.first else {
            return ProviderAvailability(available: false,
                                        detail: "Cursor logs directory not found",
                                        disclosure: disclosure)
        }
        let hasLogs = !structuredLogFiles(under: root).isEmpty
        guard hasLogs else {
            return ProviderAvailability(available: false,
                                        detail: "no Cursor Structured Logs under \(root.path)",
                                        disclosure: disclosure)
        }
        return ProviderAvailability(available: true, detail: "found \(root.path)", disclosure: disclosure)
    }

    public func diagnosticSources() -> [DiagnosticSourceDescriptor] {
        candidateRoots.prefix(1).map { DiagnosticSourceDescriptor(id: .cursorStructuredLogs, url: $0) }
    }

    public func explainDataSources() -> String {
        "Reads Cursor IDE structured logs (Cursor Structured Logs*.log) under ~/Library/Application Support/Cursor/logs — only token-ring metadata (input/output/cache token counts, model name, timestamp) and workspace path announcements. Chat transcripts, store.db, and Application Support credentials are never parsed. Per-round usage is derived as positive deltas of cumulative counters. No local subscription usage-percent source is read."
    }

    public func explainRequiredPermissions() -> String {
        "Read-only access to ~/Library/Application Support/Cursor/logs (or CURSOR_LOGS when set). Needed to attribute Cursor IDE token usage per workspace and model. No credentials are read and nothing is uploaded."
    }

    public func refreshUsage(state: ScanState) throws -> (AdapterRefreshResult, ScanState) {
        var newState = state
        var events: [UsageEvent] = []
        var parseErrors = 0
        var scanned = 0
        var complete = true
        let decoder = JSONDecoder()

        for root in roots {
            let files = structuredLogFiles(under: root)
            if files.isEmpty { complete = false }
            for (url, size) in files {
                let key = url.path
                let mark = state.files[key]
                if let mark, mark.size == size, mark.offset == size { continue }
                scanned += 1

                var ctx = FileContext(from: (mark?.offset ?? 0) <= size ? mark?.context : nil)
                let startOffset = (mark != nil && mark!.offset <= size) ? mark!.offset : 0
                do {
                    let newOffset = try StructuredLogScanner.scan(
                        url: url, from: startOffset,
                        quickFilters: ["Setting token details", "startup.workspace_paths"]
                    ) { hit in
                        Self.handleLine(hit, decoder: decoder, sourcePath: url.path, ctx: &ctx,
                                        events: &events, parseErrors: &parseErrors)
                    }
                    newState.files[key] = FileScanMark(offset: newOffset, size: size, context: ctx.serialized())
                } catch {
                    parseErrors += 1
                    complete = false
                }
            }
        }

        return (AdapterRefreshResult(events: events, rateLimits: [], scannedFiles: scanned,
                                     parseErrors: parseErrors,
                                     completeness: (complete && parseErrors == 0) ? .complete
                                     : .incomplete("some sources unreadable or unparsable")),
                newState)
    }

    // MARK: - discovery

    static func isStructuredLog(_ url: URL) -> Bool {
        url.path.contains("anysphere.cursor-always-local")
            && url.lastPathComponent.contains("Cursor Structured Logs")
            && url.pathExtension == "log"
    }

    func structuredLogFiles(under root: URL) -> [(url: URL, size: Int64)] {
        let listing = JSONLScanner.listFiles(root: root, pathExtension: "log")
        return listing.files.filter { Self.isStructuredLog($0.url) }
    }

    // MARK: - parse

    struct FileContext {
        var model: String?
        var projectId: String?
        var projectName: String?
        var prevInput: Int = 0
        var prevOutput: Int = 0
        var prevCacheRead: Int = 0
        var prevCacheWriteUnknown: Int = 0

        init(from dict: [String: String]?) {
            guard let dict else { return }
            model = dict["model"]
            projectId = dict["projectId"]
            projectName = dict["projectName"]
            prevInput = Int(dict["prevInput"] ?? "") ?? 0
            prevOutput = Int(dict["prevOutput"] ?? "") ?? 0
            prevCacheRead = Int(dict["prevCacheRead"] ?? "") ?? 0
            prevCacheWriteUnknown = Int(dict["prevCacheWriteUnknown"] ?? "") ?? 0
        }

        func serialized() -> [String: String] {
            var d: [String: String] = [:]
            if let model { d["model"] = model }
            if let projectId { d["projectId"] = projectId }
            if let projectName { d["projectName"] = projectName }
            d["prevInput"] = String(prevInput)
            d["prevOutput"] = String(prevOutput)
            d["prevCacheRead"] = String(prevCacheRead)
            d["prevCacheWriteUnknown"] = String(prevCacheWriteUnknown)
            return d
        }
    }

    /// Narrow JSON envelope — only fields needed for routing; `metadata` decoded separately.
    struct LogEnvelope: Decodable {
        let message: String?
    }

    struct TokenRingMetadata: Decodable {
        let modelName: String?
        let inputTokens: String?
        let outputTokens: String?
        let cacheReadTokens: String?
        let cacheWriteTokens: String?
        let workspacePaths: String?
    }

    static func handleLine(_ hit: StructuredLogScanner.LineHit, decoder: JSONDecoder, sourcePath: String,
                           ctx: inout FileContext, events: inout [UsageEvent], parseErrors: inout Int) {
        guard let ts = parseLogTimestamp(hit.data) else { return }
        guard let jsonStart = hit.data.firstIndex(of: UInt8(ascii: "{")) else { return }
        let jsonData = Data(hit.data[jsonStart...])
        guard let envelope = try? decoder.decode(LogEnvelope.self, from: jsonData),
              let message = envelope.message else { return }

        if message == "cursor_agent_exec.startup.workspace_paths" {
            if let meta = try? decoder.decode(WrappedMetadata.self, from: jsonData),
               let path = firstWorkspacePath(from: meta.metadata?.workspacePaths) {
                ctx.projectId = path
                ctx.projectName = URL(fileURLWithPath: path).lastPathComponent
            }
            return
        }

        guard message == "Setting token details for client token ring" else { return }

        struct Wrapped: Decodable {
            let metadata: TokenRingMetadata?
        }
        guard let wrapped = try? decoder.decode(Wrapped.self, from: jsonData),
              let meta = wrapped.metadata else {
            parseErrors += 1
            return
        }

        if let model = meta.modelName, !model.isEmpty { ctx.model = model }

        let cur = TokenBreakdown(
            input: parseInt(meta.inputTokens),
            output: parseInt(meta.outputTokens),
            cacheRead: parseInt(meta.cacheReadTokens),
            cacheWriteUnknown: parseInt(meta.cacheWriteTokens)
        )
        guard let delta = positiveDelta(
            prev: TokenBreakdown(input: ctx.prevInput, output: ctx.prevOutput,
                                 cacheRead: ctx.prevCacheRead,
                                 cacheWriteUnknown: ctx.prevCacheWriteUnknown),
            cur: cur
        ) else {
            ctx.prevInput = cur.input
            ctx.prevOutput = cur.output
            ctx.prevCacheRead = cur.cacheRead
            ctx.prevCacheWriteUnknown = cur.cacheWriteUnknown
            return
        }

        ctx.prevInput = cur.input
        ctx.prevOutput = cur.output
        ctx.prevCacheRead = cur.cacheRead
        ctx.prevCacheWriteUnknown = cur.cacheWriteUnknown

        let stem = URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent
        let id = "cu:\(stem):\(hit.byteOffset)"

        events.append(UsageEvent(
            id: id,
            providerId: "cursor-ide",
            projectId: ctx.projectId,
            projectName: ctx.projectName,
            modelId: ctx.model,
            timestamp: ts,
            tokens: delta,
            sourceKind: "cursor-structured-log",
            sourcePath: sourcePath
        ))
    }

    struct WrappedMetadata: Decodable {
        let metadata: TokenRingMetadata?
    }

    static func parseInt(_ raw: String?) -> Int {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return 0 }
        return Int(raw) ?? 0
    }

    /// Positive delta only; cumulative regression → nil (caller resets baseline, no event).
    static func positiveDelta(prev: TokenBreakdown, cur: TokenBreakdown) -> TokenBreakdown? {
        if prev.total == 0 { return cur.total > 0 ? cur : nil }
        if cur.input < prev.input || cur.output < prev.output { return nil }
        let delta = TokenBreakdown(
            input: max(0, cur.input - prev.input),
            output: max(0, cur.output - prev.output),
            cacheRead: max(0, cur.cacheRead - prev.cacheRead),
            cacheWriteUnknown: max(0, cur.cacheWriteUnknown - prev.cacheWriteUnknown)
        )
        return delta.total > 0 ? delta : nil
    }

    static func firstWorkspacePath(from jsonArrayString: String?) -> String? {
        guard let raw = jsonArrayString?.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: raw) as? [String],
              let first = arr.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !first.isEmpty else { return nil }
        return first
    }

  private static let logTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = .current
        return f
    }()

    static func parseLogTimestamp(_ line: Data) -> Date? {
        guard let prefix = String(data: line.prefix(23), encoding: .utf8) else { return nil }
        return logTimestampFormatter.date(from: prefix)
    }
}

// MARK: - Structured log scanner (.log lines, not JSONL)

enum StructuredLogScanner {

    struct LineHit {
        let data: Data
        let byteOffset: Int64
    }

    @discardableResult
    static func scan(url: URL, from offset: Int64, quickFilters: [String],
                     handler: (LineHit) -> Void) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        var start = offset
        if start > fileSize { start = 0 }
        try handle.seek(toOffset: UInt64(start))

        let filters = quickFilters.map { Data($0.utf8) }
        let chunkSize = 4 * 1024 * 1024
        var carry = Data()
        var carryStart = start
        var consumed = start

        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            carry.append(chunk)

            var lineStartIndex = carry.startIndex
            var lineStartOffset = carryStart
            var searchFrom = carry.startIndex
            while let nl = carry[searchFrom...].firstIndex(of: 0x0A) {
                let line = carry[lineStartIndex..<nl]
                let lineLen = Int64(carry.distance(from: lineStartIndex, to: nl)) + 1
                if !line.isEmpty, matches(line, filters: filters) {
                    handler(LineHit(data: Data(line), byteOffset: lineStartOffset))
                }
                lineStartOffset += lineLen
                consumed = lineStartOffset
                lineStartIndex = carry.index(after: nl)
                searchFrom = lineStartIndex
            }
            if lineStartIndex > carry.startIndex {
                carry.removeSubrange(carry.startIndex..<lineStartIndex)
                carryStart = consumed
            }
        }
        return consumed
    }

    private static func matches(_ line: some Collection<UInt8>, filters: [Data]) -> Bool {
        let lineData = Data(line)
        if filters.isEmpty { return true }
        for f in filters where lineData.range(of: f) != nil { return true }
        return false
    }
}