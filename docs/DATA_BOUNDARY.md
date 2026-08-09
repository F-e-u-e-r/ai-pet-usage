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
| Grok CLI `auth.json` → the session token (only while the **opt-in** Grok quota card is on; *Phase 1, approved ahead of implementation* §) | Narrow § | No | No | No | **Only** as auth headers to `cli-chat-proxy.grok.com` (HTTPS, redirects refused) |
| Codex `auth.json` → the access token + account id (only while the **opt-in** Codex usage card is on; *Phase 1, approved ahead of implementation* §) | Narrow § | No | No | No | **Only** as the `Authorization` header to `chatgpt.com` (HTTPS, redirects refused) |
| Grok / Codex quota, credits & plan responses (received) | Received (opt-in) | No — memory only; **exception:** Codex official rate-limit readings fold into the existing "Limit percentages" row (`limits-state.json`) above | No | No | Received only; never re-sent |
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
displayed** — only the declared usage/metadata fields are kept. All adapters now
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

§ **The Grok/Codex token reads, precisely (Phase 1 amendment — approved ahead of
implementation; each lands only behind its own default-off toggle).** Same reviewed pattern as
the opencode key (‡): read only while that provider's opt-in card is enabled, only at request
time; the file is refused above 1 MB; only the single documented field(s) are **decoded**
(Grok: the session token from `~/.grok/auth.json`, honoring `GROK_HOME`; Codex:
`tokens.access_token` + `account_id` from `~/.codex/auth.json`, honoring `CODEX_HOME`) — no
other entry is ever materialized. The token lives only inside the single fetch, goes out only
as auth headers to the one hardcoded HTTPS host per provider (all redirects refused), and is
never persisted, logged, exported, displayed, or placed in a URL/process argument. The app
performs **zero token lifecycle management**: it never refreshes or writes back a token (Grok's
refresh rotates the refresh token and would log the user's CLI out); a 401 only renders a fixed
"run `<cli>` once to re-log in" prompt. After a 401, no further network call is made until the
credential file's mtime/size changes or the user manually refreshes. `account_id` exists only
in the memory of a single request — never persisted, shown, or exported. Provider env vars
(e.g. `XAI_API_KEY`) are deliberately ignored, same rationale as `OPENROUTER_API_KEY`.
Disabling a toggle cancels in-flight work and clears that provider's in-memory snapshot.
Errors render from the fixed closed vocabulary — never raw error/response text.

### Network egress (four opt-in calls, all off by default; two shipped + two approved for Phase 1)

1. The **opt-in** GitHub Releases update check (Settings → General; a manual "Check for Updates…" makes the
   same request). Its request body/query carries **no usage data**; the headers the app sets are
   `User-Agent: AIPetUsage/<app-version>` and `Accept: application/vnd.github+json` (the GitHub API media
   type) — no OS, no usage.
2. The **opt-in** OpenRouter credits check (Settings → Providers): `GET https://openrouter.ai/api/v1/credits`
   about every 15 minutes and on manual Refresh, with headers `Authorization` (the opencode key, ‡ above),
   `Accept: application/json`, and `User-Agent: AIPetUsage/<app-version>` — no usage data, no OS string. The
   response (credit totals) stays in memory and is never re-sent, persisted, or exported. Hardcoded HTTPS
   host, system TLS trust; no certificate pinning.
3. *(Phase 1, approved ahead of implementation)* The **opt-in** Grok quota check:
   `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` on the same ~15-minute/manual cadence,
   auth headers from the Grok CLI login (§ above) — no usage data sent. Response (usage %, period, plan)
   is memory-only.
4. *(Phase 1, approved ahead of implementation)* The **opt-in** Codex usage check:
   `GET https://chatgpt.com/backend-api/wham/usage` on the same cadence, `Authorization` from the Codex
   CLI login (§ above) — no usage data sent. Credits/plan stay memory-only; official rate-limit readings
   feed the existing LimitEngine and its persisted `limits-state.json` (an already-allowed class). The
   read-only reset-credits display may share this call's auth; a credit-**consuming** endpoint is never
   called.

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
auth material stays **No** everywhere except the reviewed credential rows above (the opencode key ‡ and the
Phase-1 Grok/Codex tokens §): each may appear **only** as auth headers of its own opt-in request to its one
hardcoded host, never in storage, reports, diagnostics, or any other host. "Usage token counts" (allowed in ledger/report/diag) are **not** the same as
"auth tokens / keys". See [`CONTRIBUTING.md`](../CONTRIBUTING.md) and
[`ADAPTER_CONTRACT.md`](ADAPTER_CONTRACT.md).
