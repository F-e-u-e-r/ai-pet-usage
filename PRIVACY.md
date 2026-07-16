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
  extracted into the app's data, stored, or shown.)
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
declares only those fields — message content is not among them.

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

## The one network call

The **only** thing this app sends over the network is an **opt-in** check for app updates against the GitHub
Releases API (Settings → General). It sends **no usage data**: the headers the app sets are
`User-Agent: AIPetUsage/<app-version>` and `Accept: application/vnd.github+json` (the GitHub API media
type) — no OS string, no usage. Notes:

- Automatic checking is **off by default**; a manual "Check for Updates…" makes the same request on demand,
  and "View update…" opens the release page in your browser.
- The request goes over the system's standard networking, so — as with any HTTPS call — GitHub receives
  ordinary connection metadata (such as your IP address) and any system-managed HTTP headers. That is not
  usage telemetry, but it is not zero-metadata.
- The app never contacts OpenRouter or any pricing service at runtime; the bundled price list is generated
  offline by the maintainer.

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
