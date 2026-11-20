import Foundation

/// Reads the Agy CLI (`agy`) local brain transcripts under
/// `~/.gemini/antigravity-cli/brain/<conversation-uuid>/.system_generated/logs/transcript.jsonl`.
/// Only per-turn token fields on model lines are decoded; prompts, thinking, and tool payloads
/// (`content`, `thinking`, `tool_calls`) are never decoded into retained objects.
/// Workspace paths come from a narrow read of `cache/conversation_metadata.json`
/// (`summary.WorkspaceURIs` only, keyed by conversation id matching the brain folder name).
/// Official quota buckets come from `agy -p "/usage"` on refresh (may use the CLI's network/auth).
/// Token totals remain transcript-only (`providerId: antigravity` / pricing namespace).
public struct AgyAdapter: ProviderAdapter {
    public let providerId = "antigravity"
    public var reportedLimitCapability: ReportedLimitCapability { .provides(windows: [.fiveHour, .weekly]) }
    public var historyModel: ProviderHistoryModel { .rebuildableHistory }
    public let displayName = "Antigravity"

    private let brainRoots: [URL]
    private let conversationMetadataURLs: [URL]
    /// When false, refresh only reads local transcripts (never spawns `agy /usage`).
    private let enableOfficialQuotaFetch: Bool
    private let quotaFetcher: () -> AntigravityQuotaSnapshot?

    public var roots: [URL] {
        brainRoots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public init(brainRoots: [URL]? = nil, conversationMetadataURLs: [URL]? = nil,
                enableOfficialQuotaFetch: Bool = false,
                quotaFetcher: @escaping () -> AntigravityQuotaSnapshot? = { AntigravityQuotaFetcher.fetch() }) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cliHome = home.appendingPathComponent(".gemini/antigravity-cli")
        self.brainRoots = brainRoots ?? [cliHome.appendingPathComponent("brain")]
        self.conversationMetadataURLs = conversationMetadataURLs
            ?? [cliHome.appendingPathComponent("cache/conversation_metadata.json")]
        self.enableOfficialQuotaFetch = enableOfficialQuotaFetch
        self.quotaFetcher = quotaFetcher
    }

    static func builtinRoots() -> [(url: URL, label: String)] {
        [(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/brain"),
          "~/.gemini/antigravity-cli/brain")]
    }

    public func detectAvailability() -> ProviderAvailability {
        let disclosure = RootDisclosure.classify(selectedRoot: roots.first,
                                                 candidates: brainRoots,
                                                 builtin: Self.builtinRoots())
        guard let root = roots.first else {
            return ProviderAvailability(available: false, detail: "~/.gemini/antigravity-cli/brain not found",
                                        disclosure: disclosure)
        }
        return ProviderAvailability(available: true, detail: "found \(root.path)", disclosure: disclosure)
    }

    public func diagnosticSources() -> [DiagnosticSourceDescriptor] {
        brainRoots.prefix(1).map { DiagnosticSourceDescriptor(id: .agyBrain, url: $0) }
    }

    public func explainDataSources() -> String {
        "Reads Antigravity CLI brain transcripts (transcript.jsonl) under ~/.gemini/antigravity-cli/brain — per-turn input/output tokens and cache_read deltas. Optional Settings → Antigravity official quota runs `agy -p \"/usage\" --output-format json` when enabled (may trigger agy sign-in). Workspace paths come from cache/conversation_metadata.json. Prompts and message bodies are never read."
    }

    public func explainRequiredPermissions() -> String {
        "Read-only access to ~/.gemini/antigravity-cli/brain and cache/conversation_metadata.json. Needed to attribute token usage per project and model. No credentials are read and nothing is uploaded."
    }

    public func refreshUsage(state: ScanState) throws -> (AdapterRefreshResult, ScanState) {
        var newState = state
        var events: [UsageEvent] = []
        var parseErrors = 0
        var scanned = 0
        var complete = true
        let decoder = JSONDecoder()
        let workspaceByConversation = Self.loadConversationWorkspaces(from: conversationMetadataURLs)

        for root in roots {
            // Agy transcripts live under `<uuid>/.system_generated/logs/` — must enumerate dot dirs.
            let listing = JSONLScanner.listFiles(root: root, pathExtension: "jsonl", includeHiddenFiles: true)
            if !listing.complete { complete = false }
            for (url, size) in listing.files {
                guard Self.isTranscriptLog(url) else { continue }
                let key = url.path
                let mark = state.files[key]
                if let mark, mark.size == size, mark.offset == size { continue }
                scanned += 1

                let conversationId = Self.conversationId(from: url)
                let projectId = conversationId.flatMap { workspaceByConversation[$0] }
                var ctx = FileContext(from: (mark?.offset ?? 0) <= size ? mark?.context : nil)
                if ctx.model == nil, let cached = mark?.context?["model"], !cached.isEmpty {
                    ctx.model = cached
                }
                if let projectId {
                    ctx.projectId = projectId
                    ctx.projectName = URL(fileURLWithPath: projectId).lastPathComponent
                }

                let startOffset = (mark != nil && mark!.offset <= size) ? mark!.offset : 0
                do {
                    let newOffset = try JSONLScanner.scan(
                        url: url, from: startOffset, quickFilters: ["input_tokens"]
                    ) { hit in
                        Self.parseLine(hit.data, decoder: decoder, conversationId: conversationId,
                                       byteOffset: hit.byteOffset, sourcePath: url.path, ctx: &ctx,
                                       events: &events, parseErrors: &parseErrors)
                    }
                    newState.files[key] = FileScanMark(offset: newOffset, size: size, context: ctx.serialized())
                } catch {
                    parseErrors += 1
                    complete = false
                }
            }
        }

        var rateLimits: [RateLimitReading] = []
        var quotaSnapshot: AntigravityQuotaSnapshot?
        if enableOfficialQuotaFetch,
           let snapshot = quotaFetcher(),
           let reading = AntigravityQuotaFetcher.geminiModelsRateLimit(from: snapshot) {
            quotaSnapshot = snapshot
            rateLimits = [reading]
        }
        return (AdapterRefreshResult(events: events, rateLimits: rateLimits, scannedFiles: scanned,
                                     parseErrors: parseErrors,
                                     completeness: (complete && parseErrors == 0) ? .complete
                                     : .incomplete("some sources unreadable or unparsable"),
                                     antigravityQuota: quotaSnapshot),
                newState)
    }

    // MARK: - conversation metadata

    struct ConversationMetadataFile: Decodable {
        struct Entry: Decodable {
            struct Summary: Decodable { let WorkspaceURIs: [String]? }
            let summary: Summary?
        }
        let conversations: [String: Entry]?
    }

    /// conversation id → workspace path (first `file://` WorkspaceURI only).
    static func loadConversationWorkspaces(from urls: [URL]) -> [String: String] {
        let decoder = JSONDecoder()
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let parsed = try? decoder.decode(ConversationMetadataFile.self, from: data),
                  let conversations = parsed.conversations else { continue }
            var out: [String: String] = [:]
            for (cid, entry) in conversations {
                guard let uri = entry.summary?.WorkspaceURIs?.first,
                      let path = workspacePath(from: uri) else { continue }
                out[cid] = path
            }
            if !out.isEmpty { return out }
        }
        return [:]
    }

    static func workspacePath(from uri: String) -> String? {
        guard uri.hasPrefix("file://"), let url = URL(string: uri) else { return nil }
        let path = url.path
        return path.isEmpty ? nil : path
    }

    // MARK: - paths

    static func isTranscriptLog(_ url: URL) -> Bool {
        guard url.lastPathComponent == "transcript.jsonl" else { return false }
        let logs = url.deletingLastPathComponent()
        guard logs.lastPathComponent == "logs" else { return false }
        let generated = logs.deletingLastPathComponent()
        return generated.lastPathComponent == ".system_generated"
    }

    static func conversationId(from transcript: URL) -> String? {
        // …/brain/<uuid>/.system_generated/logs/transcript.jsonl
        let logs = transcript.deletingLastPathComponent()
        guard logs.lastPathComponent == "logs" else { return nil }
        let generated = logs.deletingLastPathComponent()
        guard generated.lastPathComponent == ".system_generated" else { return nil }
        let uuid = generated.deletingLastPathComponent().lastPathComponent
        return uuid.isEmpty ? nil : uuid
    }

    // MARK: - parse

    struct FileContext {
        var model: String?
        var projectId: String?
        var projectName: String?
        /// Last observed cumulative `cache_read_tokens` in this transcript (per-file scan cursor).
        var lastCacheRead: Int = 0

        init(from dict: [String: String]?) {
            guard let dict else { return }
            model = dict["model"]
            projectId = dict["projectId"]
            projectName = dict["projectName"]
            if let s = dict["lastCacheRead"], let v = Int(s) { lastCacheRead = v }
        }

        func serialized() -> [String: String] {
            var d: [String: String] = [:]
            if let model { d["model"] = model }
            if let projectId { d["projectId"] = projectId }
            if let projectName { d["projectName"] = projectName }
            d["lastCacheRead"] = String(lastCacheRead)
            return d
        }
    }

    /// `cache_read_tokens` in transcripts is a **cumulative** context counter (resets after compaction).
    /// Emit positive deltas only; on regression, reset baseline (same pattern as Grok session counters).
    static func cacheReadDelta(raw: Int, ctx: inout FileContext) -> Int {
        if raw < ctx.lastCacheRead {
            ctx.lastCacheRead = raw
            return raw
        }
        let delta = raw - ctx.lastCacheRead
        ctx.lastCacheRead = raw
        return delta
    }

    struct TokenLine: Decodable {
        let step_index: Int?
        let created_at: String?
        let input_tokens: Int?
        let cache_read_tokens: Int?
        let output_tokens: Int?
        let model: String?
    }

    static func parseLine(_ data: Data, decoder: JSONDecoder, conversationId: String?, byteOffset: Int64,
                          sourcePath: String, ctx: inout FileContext, events: inout [UsageEvent],
                          parseErrors: inout Int) {
        guard let rec = try? decoder.decode(TokenLine.self, from: data) else {
            parseErrors += 1
            return
        }
        if let model = rec.model, !model.isEmpty { ctx.model = model }

        let input = rec.input_tokens ?? 0
        let output = rec.output_tokens ?? 0
        let cacheRead = cacheReadDelta(raw: rec.cache_read_tokens ?? 0, ctx: &ctx)
        let tokens = TokenBreakdown(input: input, output: output, cacheRead: cacheRead)
        guard tokens.total > 0 else { return }

        guard let tsRaw = rec.created_at, let timestamp = ISO8601.parse(tsRaw) else { return }
        let step = rec.step_index ?? -1
        let cid = conversationId ?? "unknown"
        let id = step >= 0 ? "ag:\(cid):\(step)" : "ag:\(cid):\(byteOffset)"

        events.append(UsageEvent(
            id: id,
            providerId: "antigravity",
            projectId: ctx.projectId,
            projectName: ctx.projectName,
            modelId: ctx.model,
            timestamp: timestamp,
            tokens: tokens,
            sourceKind: "agy-transcript",
            sourcePath: sourcePath
        ))
    }
}