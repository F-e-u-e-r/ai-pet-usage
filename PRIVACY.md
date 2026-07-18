# Privacy

AI Pet Usage is a **local-first** macOS menu-bar app. It reads AI-coding-CLI usage logs that are already on
your Mac and shows quota / cost / activity, with a desktop pet. This document is the plain-language version
of the boundary; [`docs/DATA_SOURCES.md`](docs/DATA_SOURCES.md) is the exact, file-by-file source of truth
and [`docs/DATA_BOUNDARY.md`](docs/DATA_BOUNDARY.md) is a per-data-class checklist of where each thing can go.

## The promise

- Your usage data **stays on your Mac.** No upload, no telemetry, no account, no login.
- The app **does not extract, retain, write, export, or display** prompt text, assistant message content,
  tool-call payloads, attachments, or auth / credential files. (Log files are scanned as raw text to find
  the usage lines; only the declared usage / metadata fields are pulled out — message content is never
  extracted into the app's data, stored, or shown.) The single reviewed exception: if you enable the
  **opt-in** OpenRouter credits monitor, one API key is read narrowly from opencode's `auth.json` and used
  only as a request header — see "The network calls" below and `docs/DATA_BOUNDARY.md` ‡.
- Numbers are honest: provider-reported figures are labelled **high-confidence**, computed ones
  **estimated**, and a reading that is old is labelled **stale**. A genuinely-unknown value is left **blank**,
  not shown as a confident `0` (an expired window that has rolled over reads ~`0%` **labelled estimated** —
  that's a real recovered state, not a faked number).

## What it reads

Read-only, from the documented locations only (full list in `docs/DATA_SOURCES.md`): per-message **token
counts**, model IDs, project paths (cwd), timestamps, and — where the provider exposes them locally —
official **rate-limit percentages** and reset times. It also reads a few narrow labels: your Claude
subscription **plan** (two keys from `~/.claude.json`) and Codex **plan** (a `plan_type` field on its
rate-limit line), the Grok **tier** label (one field from a billing log line), and the Claude **statusline**
payload if a hook saves it locally. Claude session lines are parsed through a **narrow decoder** that
declares only those fields — message content is not among them. If you enable the optional OpenRouter
credits monitor (below), it additionally reads **one** API key from opencode's `auth.json` — used only as
the request's `Authorization` header, never stored or shown.

## What stays local, and what you share

- **On disk**, under `~/Library/Application Support/AIPetUsage/`, the ledger stores normalized usage events.
  For stable grouping these include a **project identifier** which, when the source gives a local cwd, is a
  **local path**, plus the **source log-file path**; the scan-state file is keyed by full log-file paths.
  These never leave your Mac, but they mean **sharing the raw folder is not as safe as sharing an export.**
- **What you choose to export is redacted at the point of export.** An HTML report **actively redacts**
  project names to a basename and emits **closed-vocabulary** data-quality notes, and never includes prompts
  or message content. Its remaining text fields — model IDs and pricing-source labels — are provider/curated
  values shown after a defensive absolute-path scrub (a path-shaped model ID is reduced to its basename; a
  pricing label containing an absolute path collapses to a fixed placeholder); token counts and limit
  percentages are numbers. The `aipet diag`
  diagnostic goes
  further: it is **closed-vocabulary** (status codes, counts, bucketed ages) with **no project names,
  prompts, or real local paths** — its source labels are fixed canonical names like `~/.codex/sessions`,
  never your actual paths — built to be pasteable into a bug report. (Note: `aipet status` / `aipet sources`
  suppress raw paths and raw error text by default — a custom log location prints as
  `custom root (details hidden)`, errors as a fixed line, `--full` opts back into the raw text for local
  debugging — but they still show project basenames, plan labels and exact times, so they are convenience
  output, not hardened share artifacts. Prefer `aipet diag` or an HTML report when sharing.)

## The network calls (two, each opt-in and off by default)

This app sends nothing over the network unless you turn one of these on — and neither sends usage data:

1. **Update check** (Settings → General): an opt-in check against the GitHub Releases API. The headers the
   app sets are `User-Agent: AIPetUsage/<app-version>` and `Accept: application/vnd.github+json` (the
   GitHub API media type) — no OS string, no usage. A manual "Check for Updates…" makes the same request on
   demand, and "View update…" opens the release page in your browser.
2. **OpenRouter credits** (Settings → Providers): an opt-in balance check for people who use opencode with
   OpenRouter prepaid credits. When on, the app reads the OpenRouter API key that **opencode** saved in
   `~/.local/share/opencode/auth.json` (or `$XDG_DATA_HOME/opencode/auth.json` when that variable is set;
   the file is read as bytes; only the `openrouter` entry is decoded —
   no other CLI's credentials are ever materialized) and calls `https://openrouter.ai/api/v1/credits` about
   every 15 minutes and on manual Refresh. The key is sent **only** to openrouter.ai as the `Authorization`
   header over HTTPS (dedicated in-memory session, redirects refused) and is never stored, logged,
   exported, or displayed; the returned credit totals stay in memory and are never written to disk or
   re-sent anywhere. The app deliberately ignores the `OPENROUTER_API_KEY` environment variable.

Notes:

- Requests go over the system's standard networking, so — as with any HTTPS call — the contacted host
  receives ordinary connection metadata (such as your IP address) and any system-managed HTTP headers. That
  is not usage telemetry, but it is not zero-metadata.
- Beyond these two opt-in calls the app contacts no other host. The bundled price list is generated offline
  by the maintainer — the pricing pipeline never runs at runtime, and enabling the credits monitor fetches
  your credit totals only, never prices or model catalogs.

## Resetting / deleting

There is no one-click "erase everything" yet (Settings → Data & Privacy has **Full Reindex**, which
*rebuilds* the ledger from your logs — not an erase). To delete app data: **quit the app**, then remove
`~/Library/Application Support/AIPetUsage/`. That resets the app settings stored there (so any provider you
disabled becomes default-enabled again) but **not** your update-check preferences (those live in macOS
system storage), and it does **not** delete your provider logs (`~/.claude`, `~/.codex`, `~/.grok`) — so the
next refresh may rescan and rebuild. If you set up scheduled export, remove its LaunchAgent and turn off
launch-at-login too.

## Status

Alpha software, provided as-is with no warranty. Found a privacy problem? Please report it **privately** —
see [`SECURITY.md`](SECURITY.md). The boundary a change must not cross is enumerated in
[`docs/DATA_BOUNDARY.md`](docs/DATA_BOUNDARY.md).
