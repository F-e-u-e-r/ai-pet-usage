# Data Sources

This document lists exactly which local files the app reads, what is extracted, and why. It is the source of truth for the in-app "Providers" and "Data & Privacy" settings copy.

Everything is read-only. Nothing is uploaded. There is no telemetry and no account login.

## Codex (`providerId: codex`)

**Paths read**

- `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
- `~/.codex/archived_sessions/**/rollout-*.jsonl`
- `CODEX_HOME` is honored when set.

**Lines consumed** (all other line types are skipped without parsing)

| line | fields extracted | purpose |
|---|---|---|
| `session_meta` | `payload.cwd` | project attribution |
| `turn_context` | `payload.cwd`, `payload.model` | project + model attribution |
| `event_msg` / `token_count` | `info.total_token_usage` (input, cached_input, output), `rate_limits.primary/secondary` (`used_percent`, `window_minutes`, `resets_at` / `resets_in_seconds`), `plan_type`, line `timestamp` | token ledger events (per-turn deltas of cumulative totals) and official 5-hour / weekly limit readings |

**Not read**: prompts, assistant messages, tool call payloads, `history.jsonl`, auth files.

Codex limit percentages are **provider-reported** (confidence: high). The ledger event for each turn is the delta of `total_token_usage` against the previous `token_count` in the same file; `input` is normalized to non-cached input (`input_tokens − cached_input_tokens`), cache reads are tracked separately.

## Claude Code (`providerId: claude-code`)

**Paths read**

- `~/.claude/projects/<project-slug>/*.jsonl`
- `CLAUDE_CONFIG_DIR/projects` and `~/.config/claude/projects` when present.

**Lines consumed**

| line | fields extracted | purpose |
|---|---|---|
| `type == "assistant"` | `message.id`, `message.model`, `message.usage` (input, output, cache_read, cache_creation incl. 5m/1h split), `requestId`, `cwd`, `timestamp`, `uuid` | token ledger events |

Deduplication key is `message.id + requestId` (streaming rewrites the same message several times; only the first occurrence is counted). `model == "<synthetic>"` lines are skipped.

**Not read**: prompts, message contents, attachments, file-history snapshots.

**Official Claude Code limits (preferred source).** Claude Code feeds its statusline command a JSON payload that includes `rate_limits` — the official `five_hour` / `seven_day` `used_percentage` and `resets_at` (unix). Any statusline hook that saves this payload to disk gives the app provider-reported limits (confidence: high), exactly like Codex. The adapter checks:

- `~/Library/Application Support/AIPetUsage/claude-statusline.json` — written by this repo's own hook, `Scripts/claude-statusline-hook.sh` (install via `settings.json → statusLine`)
- `~/.claude/usage-status.json` — the same payload as saved by other statusline tools

**Fallback estimation.** Without a statusline payload, session logs contain only token counts, so the app estimates the 5-hour window with the standard block rule (first event floors to the hour, window = start + 5h) and shows a percent only when the user sets a token budget in Settings → Limits. Weekly is a rolling 7-day sum. Estimated values are always labelled `estimated`.

## Grok Code (`providerId: grok-code`)

**Paths read**

- `~/.grok/sessions/<url-encoded project path>/<session-id>/updates.jsonl`
- Sibling `summary.json` and `signals.json` in the same session folder (metadata only).
- `GROK_HOME` is honored when set — it **replaces** `~/.grok`, so sessions live at `$GROK_HOME/sessions`.

**Lines consumed** (only lines carrying a token counter are parsed; every other line is skipped without parsing)

| line | fields extracted | purpose |
|---|---|---|
| `session/update` with `_meta.totalTokens` | `_meta.totalTokens`, `_meta.eventId`, line `timestamp` (epoch seconds; `_meta.agentTimestampMs` as fallback) | token ledger events (per-turn growth of the cumulative counter) |
| `summary.json` | `current_model_id`, `info.cwd` | model + project attribution |
| `signals.json` | `primaryModelId` | model attribution fallback only |

The session-folder name is the URL-encoded project path and is decoded to attribute usage to a project. Message contents (`params.update`) are never decoded — each line is read through a narrow parser that only sees the token counter and its metadata.

**Not read**: prompts, assistant/message contents, tool call payloads, `events.jsonl`, search indexes, logs, auth/credential files.

**Token figures are estimates that undercount.** Grok's local log exposes only a cumulative, context-size-like token counter per session, and it even regresses after context compaction (a later line reports a smaller value). The ledger event for each turn is the positive growth of that counter since the previous turn; on a regression the baseline is reset and no negative event is produced. Because the counter tracks context size rather than billed input/output, these figures **undercount actual billed usage** and have no input/output/cache split (all growth is recorded as input, confidence: estimated). **Grok exposes no usage limits locally, so no usage percent is provided.**

**Pricing: curated entries only, and costs are lower-bound estimates.** Auto-generated price entries are ignored for Grok (a price list refresh can never silently start pricing rough token estimates). Grok models are priced only through deliberate, source-verified curated entries or a user price override — currently `grok-4.5` ($2/$6, cache read $0.50, verified against docs.x.ai and OpenRouter 2026-07-11). Because the underlying token counts undercount billed usage, grok costs are **lower-bound estimates**, not invoices. Models without a verifiable public price (e.g. `grok-composer-2.5-fast`) stay unpriced and appear as "unknown model" rows.

## Limit calculation policy

Policy:

- Provider-wide aggregates win over any single terminal panel.
- Within one active window, a usage percent never goes **down** because an older/stale source event appeared. Newer readings can only raise it.
- A percent may drop only when the window rolls over (resets_at changes) or after an explicit **Full Reindex** — such corrections are labelled `corrected` in the UI and in reports.
- Expired windows (resets_at in the past) display as recovered (0%, confidence `estimated`) until fresh data arrives.

## Local storage

Everything lives in `~/Library/Application Support/AIPetUsage/`:

| file | content |
|---|---|
| `ledger.jsonl` | normalized usage events (append-only; 92-day retention compaction) |
| `scan-state.json` | per-file read offsets + parse context for incremental scans |
| `limits-state.json` | folded rate-limit windows (monotonic guard state) |
| `pricing-overrides.json` | user model-price overrides (highest precedence) |
| `settings.json` | app settings (`core` section is shared with the CLI) |
| `pet-state.json` | hunger / XP / feeding state |
| `refresh.lock` | flock file serializing app↔CLI write phases |

Delete the folder to reset the app completely.

## Model pricing

Prices resolve in four layers: curated list → OpenRouter-generated full list → compiled-in fallback → user overrides (highest).

- **`Sources/UsageCore/Resources/model-prices.json`** — curated list, wins over the generated one. Each entry records `source` and `effectiveFrom`. Verified 2026-07-06 against docs.claude.com (Fable 5 $10/$50, Opus 4.8 $5/$25, Sonnet 5 intro $2/$10; cache read 0.1×, write 1.25×/2×) and developers.openai.com (GPT-5.5 $5/$30 cached $0.50; GPT-5.5 Pro $30/$180; GPT-5.4 $2.50/$15).
- **`Sources/UsageCore/Resources/model-prices-generated.json`** — full long-tail list (~100 models: anthropic → claude-code, openai → codex, google → antigravity, x-ai → grok-code) generated from OpenRouter's public catalog. Regenerate with `python3 Scripts/update-price-list.py`; values cross-check against provider list prices.
- Models in neither list are **never silently priced** — they surface as "unknown model" rows and are excluded from exact totals until the user adds a price (Settings → Limits & Pricing, or `pricing-overrides.json`).

## HTML reports

Reports are static, self-contained local HTML (embedded CSS, no external requests, no JavaScript required). By default they contain project **names** only — full local paths, prompts, and message contents are never included.
