# Provider Adapter Contract

How to add or change a provider adapter without breaking the product's privacy promise or its honesty
about numbers. Read this alongside [`DATA_SOURCES.md`](DATA_SOURCES.md), which is the per-provider source
of truth for exact paths and fields, and must be updated in the same PR.

An adapter turns one AI CLI's **local** log files into normalized `UsageEvent`s and (where the provider
exposes them) `RateLimitReading`s. Adapters live in `Sources/UsageCore/*Adapter.swift` and conform to
`ProviderAdapter` (`Sources/UsageCore/Models.swift`). Existing ones — `CodexAdapter`,
`ClaudeCodeAdapter`, `GrokCodeAdapter` — are the reference implementations.

## The protocol

```swift
public protocol ProviderAdapter: Sendable {
    var providerId: String { get }        // stable slug, e.g. "codex", "claude-code", "grok-code"
    var displayName: String { get }
    var roots: [URL] { get }              // local source dirs (existence-filtered) for the file watcher
    var watchFiles: [URL] { get }         // extra individual files to watch (default: [])
    func detectAvailability() -> ProviderAvailability
    func refreshUsage(state: ScanState) throws -> (AdapterRefreshResult, ScanState)  // MUST be read-only
    func explainDataSources() -> String
    func explainRequiredPermissions() -> String
}
```

`refreshUsage` resumes from the byte offsets recorded in `ScanState` and returns new events plus the
advanced scan state. It is **incremental** (never re-reads from zero on every tick) and **read-only**.

## Hard rules

1. **Read-only, and only the documented files.** Open provider files for reading only. Never write,
   move, or touch them, and never read outside the paths listed in `DATA_SOURCES.md`. Honor the
   provider's home override env var (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `GROK_HOME`) when set.

2. **Never parse message content.** Read each line through a narrow decoder that sees only the token
   counter, ids, timestamp, model, and cwd. Prompts, assistant messages, tool-call payloads,
   attachments, auth/credential files, and search indexes are **never** decoded, logged, retained, or
   emitted. If you must open a file that also contains content (e.g. a billing/tier line deep in a log),
   extract the single field through a decoder that cannot surface anything else.

3. **No network.** Adapters do local file I/O only. The whole app has exactly two outbound calls — the
   opt-in GitHub update check and the opt-in OpenRouter credits check (both off by default) — and neither
   lives in an adapter. An adapter must never add one.

4. **Stable, source-derived dedup id.** `UsageEvent.id` must be deterministic across rescans so the
   ledger dedupes on re-read. Derive it from stable **source** identifiers (log position / provider
   ids) — never from message content. Prefix with the provider:

   | provider | `UsageEvent.id` |
   |---|---|
   | Codex | `cx:<file-stem>:<byte-offset>` |
   | Claude Code | `cc:<message.id>:<requestId>` (streaming rewrites the same message; first wins) |
   | Grok Code | `gk:<eventId>` (fallback `gk:<session-id>:<byte-offset>`) |

   Never key on wall-clock time or array index. A provider's own stable event id is best; a
   `file-stem + byte-offset` pair is the fallback when none exists.

## Honesty rules (as important as the privacy rules)

These encode the product's core promise: **a shown number is either real or labelled an estimate — never
a confident fake.**

- **`Confidence` is `.high` only for provider-reported values.** Use `.high` when the number comes
  straight from the provider (Codex/Claude official `rate_limits`). Anything you compute, infer, or
  approximate is `.estimated`. There is no third "looks probably right" tier — do not fake `.high`.

- **Missing ≠ zero.** If a value is absent, carry the unknown through — do not substitute `0`, and do not
  invent a limit percent the provider didn't report. Grok exposes no limits locally, so it emits **no**
  usage percent (not `0%`). A model with no verifiable price stays unpriced (shown as `$X+` / "unknown
  model"), never `$0`.

- **Rate-limit windows are normalized by duration, not JSON position.** `RateLimitReading.primary` is
  always the 5-hour window and `secondary` the weekly window, classified by `window_minutes`
  (`300` → 5h, `10080` → weekly). Never assume the provider's `primary`/`secondary` slots map
  positionally — Codex, for one, does not guarantee that.

- **Counters that can regress must not emit negative usage.** If the source is a cumulative counter (Grok
  regresses after compaction; Codex/Claude report cumulative totals per file), emit the **positive delta**
  since the previous turn; on a regression, reset the baseline and emit nothing rather than a negative.
  Document any known undercount in `DATA_SOURCES.md` (Grok's counter tracks context size and undercounts
  billed usage — so its costs are lower-bound estimates, and that is stated in the UI).

- **Respect the monotonic limit policy.** A folded usage percent may only drop through the documented
  channels (window rollover, Full Reindex, or two consecutive lower official readings) — see
  `DATA_SOURCES.md` § "Limit calculation policy". An adapter emits raw `RateLimitReading`s; it must not
  try to lower a stored percent with a single stale/lower reading.

## Availability must fail honest

`detectAvailability()` reports genuine local state — installed / not-installed / no-data. An adapter that
can't read its files reports that; it does not report healthy or fabricate placeholder data. "Can't check"
is never rendered as "fine".

## Tests & fixtures (required for any adapter PR)

Local log formats change without notice, so every adapter change ships with a **redacted fixture** and a
test that parses it — this is what keeps a fix from silently regressing when the format drifts.

- Add a small fixture under the test resources with **realistic shape but scrubbed values**: no real
  prompts, message bodies, tokens, account ids, or full local paths. A few lines that reproduce the
  parsing case is enough.
- Cover: the happy path (correct event count, tokens, model, project), the **dedup** case (re-scanning the
  same bytes yields no duplicate events), a **regression/rollover** case for cumulative counters, and a
  **malformed/partial line** (skipped without throwing away the whole file).
- Assert honesty: unavailable limits stay absent (not `0%`), estimated values carry `.estimated`, unknown
  models stay unpriced.
- Run `Scripts/swiftpm.sh run usagecore-tests` (the custom XCTest harness) and keep CI green.

## PR checklist for an adapter change

- [ ] `refreshUsage` is read-only and incremental; only documented paths are opened.
- [ ] No prompts / message bodies / tool payloads / auth files are decoded, logged, or emitted.
- [ ] No outbound network call added.
- [ ] `UsageEvent.id` is a stable, source-derived, provider-prefixed key (never from message content).
- [ ] Rate-limit windows normalized by `window_minutes`; missing values stay absent, not `0`.
- [ ] Confidence is `.high` only for provider-reported numbers; everything else `.estimated`.
- [ ] Redacted fixture + tests added (happy path, dedup, regression/rollover, malformed line).
- [ ] `DATA_SOURCES.md` updated to match exactly what the adapter now reads.
