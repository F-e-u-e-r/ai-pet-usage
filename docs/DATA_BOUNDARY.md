# Data boundary checklist

This is the explicit boundary: for each class of data, where it is allowed to go. It is what a reviewer or a
user checks the [privacy promise](../PRIVACY.md) against, and what a code change must not quietly widen.
See [`DATA_SOURCES.md`](DATA_SOURCES.md) for the exact files and fields.

Columns:
- **Read?** — does the app read it from your machine at all.
- **Persisted locally** — whether it is written to app storage on disk, and where.
- **HTML report** — whether it can appear in an exported HTML report.
- **`aipet diag`** — whether it can appear in the redacted diagnostic.
- **Network** — whether it is ever sent off the machine.

| Data class | Read? | Persisted locally | HTML report | `aipet diag` | Network |
|---|---|---|---|---|---|
| Prompts, assistant / tool message content, attachments | Scanned as bytes, **not extracted** † | No | No | No | **No** |
| Auth files, API keys, tokens | **No** — sole exception: the row below | No | No | No | **No** |
| opencode `auth.json` → the `openrouter` API key (only while the **opt-in** credits monitor is on) | Narrow ‡ | No | No | No | **Only** as the `Authorization` header to `openrouter.ai` (HTTPS, redirects refused) |
| OpenRouter credit totals (purchased / used / derived remaining) | Received from openrouter.ai (opt-in) | No — memory only | No | No | Received only; never re-sent |
| Per-event **token counts** (usage) | Yes | `ledger.jsonl` | Yes | Yes | **No** |
| **Full local paths** — cwd/`projectId`, `sourcePath`, scan-state keys, export folder | Yes | `ledger.jsonl`, `scan-state.json`, `settings.json` (export folder), LaunchAgent | **No** (basename only) | **No** | **No** |
| Project **names** (basename, redacted) | Derived | `ledger.jsonl` (shown redacted) | Yes | No | **No** |
| Model IDs | Yes | `ledger.jsonl` | Yes | **No** | **No** |
| Limit percentages, reset times, confidence | Yes (when provider exposes) | `limits-state.json` | Yes | Yes | **No** |
| Plan / subscription-tier label | Yes (narrow) | `limits-state.json` | **No** | No | **No** |
| Activity timestamps | Yes | `ledger.jsonl` | Yes (times) | **Bucketed age only** | **No** |
| App version | — | — | No | Yes | **Version only**, in the update-check `User-Agent` |
| OS version | — | — | No | Yes | **No** (diag only; not on the wire) |

† **Scanned vs extracted.** To find usage lines, the scanner reads raw log bytes; what is guaranteed is that
message content is **never extracted into the app's data model, retained, written to disk, exported, or
displayed** — only the declared usage/metadata fields are kept. All three adapters (Claude, Codex, Grok) now
parse their matching session lines through **narrow decoders** that never build undeclared fields — prompts,
message content, instruction blobs — into an object at all. For Codex this matters concretely: rollout
`session_meta` lines carry `base_instructions` and a filter-matched `response_item` line can carry message
content; the previous `JSONSerialization` parse materialized those transiently, the narrow decoder does not.

‡ **The opencode key read, precisely.** Only while the opt-in OpenRouter credits monitor is enabled
(Settings → Providers; **off by default**), and only at request time, the app reads
`~/.local/share/opencode/auth.json` (or `$XDG_DATA_HOME/opencode/auth.json`) — the whole file necessarily
passes through memory as bytes, but only the `openrouter` entry is **decoded**; other entries (any other
CLI's credentials) are never materialized into objects, and the file is refused above 1 MB. The extracted
key lives only inside the single fetch call, goes out **only** as the `Authorization` header to
`https://openrouter.ai` (dedicated in-memory-only session, no cookies, all redirects refused), and is never
persisted, logged, exported, displayed, or placed in a URL/process argument. The `OPENROUTER_API_KEY`
environment variable is deliberately ignored by the app (it could silently select a different account than
the opencode login being monitored). Disabling the toggle cancels in-flight work and clears the in-memory
credit snapshot. Errors render from a fixed closed vocabulary — never raw error/response text.

### Network egress (two opt-in calls, both off by default)

1. The **opt-in** GitHub Releases update check (Settings → General; a manual "Check for Updates…" makes the
   same request). Its request body/query carries **no usage data**; the headers the app sets are
   `User-Agent: AIPetUsage/<app-version>` and `Accept: application/vnd.github+json` (the GitHub API media
   type) — no OS, no usage.
2. The **opt-in** OpenRouter credits check (Settings → Providers): `GET https://openrouter.ai/api/v1/credits`
   about every 15 minutes and on manual Refresh, with headers `Authorization` (the opencode key, ‡ above),
   `Accept: application/json`, and `User-Agent: AIPetUsage/<app-version>` — no usage data, no OS string. The
   response (credit totals) stays in memory and is never re-sent, persisted, or exported. Hardcoded HTTPS
   host, system TLS trust; no certificate pinning.

As with any HTTPS request over the system's standard networking, the contacted host also sees ordinary
connection metadata (e.g. IP) and any system-managed headers. Beyond these two opt-in calls the app contacts
no other host; the bundled price list is generated offline — the pricing pipeline never runs at runtime.

### Not share-hardened

`aipet status` and `aipet sources` are convenience CLI output. Their **default** output suppresses raw
local paths and raw error text (custom roots print as `custom root (details hidden)`; errors print a fixed
line; data-quality notes go through the closed-vocabulary templates; every dynamic string is
control-character-stripped) — but it still shows project **basenames**, plan labels, usage numbers and
exact times, so it is **not** a public share artifact. `--full` opts back into raw paths and raw error
text for local debugging (with a stderr warning). For anything you paste publicly, use `aipet diag` or a
default HTML report — those are the paste-hardened artifacts.

### The contributor rule

A change may not move a **No** to **Yes** in the *HTML report*, *`aipet diag`*, or *Network* columns without
review — that is the boundary this file exists to protect. Message content must stay **No** everywhere, and
auth material stays **No** everywhere except the single reviewed opencode-key row above (‡): that key may
appear **only** in the `Authorization` header of the opt-in credits request, never in storage, reports,
diagnostics, or any other host. "Usage token counts" (allowed in ledger/report/diag) are **not** the same as
"auth tokens / keys". See [`CONTRIBUTING.md`](../CONTRIBUTING.md) and
[`ADAPTER_CONTRACT.md`](ADAPTER_CONTRACT.md).
