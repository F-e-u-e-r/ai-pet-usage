# Provider Research: Antigravity & Grok Code

Status of the two v1 research/stretch providers from `ROADMAP.md` Phase 2 and `docs/REFERENCE_USAGE_PLAN.md`. Codex and Claude Code are the shipped v1 core; nothing below blocks the MVP.

Both providers stay **documentation-only** until a reliable, user-owned local data source is confirmed. We do not ship an adapter based on guessed file formats, and we never call network APIs for usage data (privacy boundary in `docs/EXPECTATIONS.md`).

**Research status (2026-07-09, gate G5 NOT passed):** web research (below) surfaced plausible local data locations for both tools, but the development machine has neither installed, so the real field shapes are **unverified**. Per the rule above, no adapter is written yet — the leads are recorded so verification can happen quickly on a machine that has the tool.

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

Web-research leads (2026-07-09, **unverified on-machine**):
- Conversation transcripts appear to be JSONL under `~/.gemini/antigravity*/…/brain/<conversation-id>/.system_generated/logs/transcript.jsonl` (plus a full `transcript_full.jsonl`); a token-monitor cache lives under `.token-monitor/rpc-cache/v1/`. If confirmed, the JSONL path could reuse `JSONLScanner`. Verify per-record token fields + timestamps + model ids before writing anything.

Decision gate: if only aggregate UI state exists (no per-event records), Antigravity ships as a **limits-only** adapter (percent + reset), with no ledger events.

## Grok Code (xAI)

Research checklist (unverified):

- Identify which client the user actually runs (grok CLI, IDE plugin, or third-party CLI wrapper) — data locations differ per client.
- For a CLI client: inspect `~/.grok*/` / `~/Library/Application Support/grok*/` for session JSONL or history databases; confirm token fields.
- Check whether the client exposes rate-limit headers/snapshots in its logs (as Codex does); that would enable high-confidence limits.
- Confirm license/ToS allows reading its local files for personal tooling (reading user-owned local files is normally fine; note anything unusual).

Web-research leads (2026-07-09, **unverified on-machine**):
- One Grok CLI variant stores session metrics in `~/.grok-cli/session.db` (**SQLite**, so it needs a new read-only SQLite reader — not `JSONLScanner`); auth in `~/.grok-cli/auth.json`; settings in `~/.grok*/user-settings.json`. Note there are several unrelated "grok-cli" projects — pin down which client the user runs first, then confirm the `session.db` schema (token columns + timestamps) before writing an adapter.

Decision gate: same as Antigravity.

## How to add an adapter once a source is confirmed

1. Capture 2–3 **synthetic** fixture lines mirroring the real shape (never commit real transcripts) into `Sources/usagecore-tests/Fixtures/`.
2. Implement `<Provider>Adapter.swift` against `ProviderAdapter`, reusing `JSONLScanner` for JSONL sources (SQLite sources need a new read-only reader).
3. Add parser + incremental-scan tests mirroring `CodexAdapterTests`.
4. Register the adapter in `UsageCoordinator.init` defaults and add a section to `docs/DATA_SOURCES.md`.
5. The pet, pages, reports, and limit engine need **no changes** — they consume normalized snapshots only.
