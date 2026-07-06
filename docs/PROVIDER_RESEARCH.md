# Provider Research: Antigravity & Grok Code

Status of the two v1 research/stretch providers from `ROADMAP.md` Phase 2 and `docs/REFERENCE_USAGE_PLAN.md`. Codex and Claude Code are the shipped v1 core; nothing below blocks the MVP.

Both providers stay **documentation-only** until a reliable, user-owned local data source is confirmed. We do not ship an adapter based on guessed file formats, and we never call network APIs for usage data (privacy boundary in `docs/EXPECTATIONS.md`).

## What an adapter needs (gate for promotion)

From `ProviderAdapter` in `Sources/UsageCore/Models.swift`, a candidate source must provide, locally and without credentials:

1. Per-turn or per-message **token counts** (input/output at minimum; cache split is a bonus).
2. A **timestamp** per record.
3. Ideally **model id** and **project/cwd** attribution.
4. Optionally provider-reported **limit percentages** (like Codex `rate_limits`) — otherwise limits fall back to estimated budgets like Claude Code.
5. A stable way to **deduplicate** records (ids or append-only files with stable offsets).

## Antigravity (Google agentic IDE)

Research checklist (unverified — to be done on a machine with Antigravity installed):

- Inspect `~/Library/Application Support/Antigravity*/` and `~/.antigravity*/` for session logs, SQLite databases, or JSONL transcripts.
- Antigravity is a VS Code fork; check `User/globalStorage/` inside its app-support tree for extension-owned state that records model usage.
- Watch for a statusline/quota surface in the IDE — if the IDE displays quota, the value exists somewhere local; trace which file changes when it updates (`fs_usage` or `find -newer`).
- Determine whether records carry model ids (Gemini variants) and workspace paths.

Decision gate: if only aggregate UI state exists (no per-event records), Antigravity ships as a **limits-only** adapter (percent + reset), with no ledger events.

## Grok Code (xAI)

Research checklist (unverified):

- Identify which client the user actually runs (grok CLI, IDE plugin, or third-party CLI wrapper) — data locations differ per client.
- For a CLI client: inspect `~/.grok*/` / `~/Library/Application Support/grok*/` for session JSONL or history databases; confirm token fields.
- Check whether the client exposes rate-limit headers/snapshots in its logs (as Codex does); that would enable high-confidence limits.
- Confirm license/ToS allows reading its local files for personal tooling (reading user-owned local files is normally fine; note anything unusual).

Decision gate: same as Antigravity.

## How to add an adapter once a source is confirmed

1. Capture 2–3 **synthetic** fixture lines mirroring the real shape (never commit real transcripts) into `Sources/usagecore-tests/Fixtures/`.
2. Implement `<Provider>Adapter.swift` against `ProviderAdapter`, reusing `JSONLScanner` for JSONL sources (SQLite sources need a new read-only reader).
3. Add parser + incremental-scan tests mirroring `CodexAdapterTests`.
4. Register the adapter in `UsageCoordinator.init` defaults and add a section to `docs/DATA_SOURCES.md`.
5. The pet, pages, reports, and limit engine need **no changes** — they consume normalized snapshots only.
