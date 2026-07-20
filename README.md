<div align="center">

# 🐾 AI Pet Usage

**A macOS desktop pet that reacts to AI usage — quota, token burn, cost, and work rhythm.**

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![Swift 5](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)
![SwiftUI + AppKit](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-6E4AFF)
![Local-first](https://img.shields.io/badge/privacy-local--first-2EA043)
[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0--only-blue)](LICENSE)

Your AI usage becomes a living companion — no dashboards to open, no commands to run.

**English** · [繁體中文](README.zh-Hant.md)

</div>

```text
  /\_/\        tokens today   ▓▓▓▓▓▓▓░░░  68%
 ( o.o )       burn rate      steady · mood: focused
  > ^ <        next reset     in 2h 14m
```

**Implemented and running.** A SwiftUI/AppKit menu-bar app with a floating pixel pet, built from scratch. The repo contains the working app (SwiftPM, [`Sources/`](Sources)) plus the docs that matter most: exactly which local files are read and why ([`docs/DATA_SOURCES.md`](docs/DATA_SOURCES.md)) and where the project is headed ([`ROADMAP.md`](ROADMAP.md)).

## ✨ Highlights

- 🍎 **Native macOS** — SwiftUI + AppKit menu-bar app with a floating pixel-pet panel.
- 📊 **Three pages, not one crowded dashboard** — Today, Limits, and Projects, plus a Trends view with usage heatmap and streaks.
- 🔌 **Provider adapters** — Codex and Claude Code (with official 5h/weekly limits); Grok Code enabled by default (token usage + plan tier; this app does not yet ingest Grok's official limits); **OpenCode** (off by default — Settings → Providers; token usage + opencode-reported cost per project/model from its local SQLite, read strictly read-only with a runtime column allowlist); Antigravity behind a research gate.
- 💳 **OpenRouter credits (opt-in, off by default)** — running opencode on OpenRouter prepaid credits? Turn on Settings → Providers → OpenRouter credits to see your remaining balance (with a bar and its age) in the menu-bar dropdown and the pet's bubble. Reads only opencode's stored key, talks only to openrouter.ai, persists nothing — details in [`docs/DATA_SOURCES.md`](docs/DATA_SOURCES.md).
- 🧮 **Local ledger + limit engine** — quota, reset windows, token burn rate, and per-model costs from a pricing registry that is sourced & dated per entry.
- 🐕 **Feeding/XP loop and mood engine** — the pet reacts to signals such as quota remaining, burn rate, stale data, focus sessions, and usage milestones.
- 📄 **Offline HTML report export** — a local, offline-readable snapshot of Today, Limits, Projects, pricing assumptions, and data-quality notes.
- 👀 **Live updates & scheduled exports** — FSEvents file-watching keeps data fresh; report export can run on a schedule.
- 🪶 **Monitor-only (low RAM) mode** — Settings → General: the floating pet window and animations are never created, and the feeding/XP engine is only instantiated in full-pet mode (switching to monitor-only releases it); usage tracking, menu bar, pages, notifications, and export keep working.
- ⌨️ **Headless `aipet` CLI** — status, reports, and sprite export from the terminal.

## 📦 Install (alpha)

**Homebrew (Apple Silicon)** — recommended:

```bash
brew install --cask F-e-u-e-r/tap/ai-pet-usage
```

This handles install, `brew upgrade`, and `brew uninstall`. **Or** grab the latest `AI-Pet-Usage-…-arm64.zip` from [Releases](https://github.com/F-e-u-e-r/ai-pet-usage/releases) and drag the app to Applications.

Build from source (about a minute; required for Intel Macs):

```bash
git clone https://github.com/F-e-u-e-r/ai-pet-usage.git
cd ai-pet-usage
Scripts/build-app.sh
open "dist/AI Pet Usage.app"
```

- **Requirements**: macOS 14+. The Homebrew cask and the prebuilt zip are Apple Silicon; building from source needs the Xcode Command Line Tools (`xcode-select --install`).
- **First launch**: the alpha is ad-hoc signed and **not notarized**, so macOS blocks it the first time. Try to open the app, then go to **System Settings → Privacy & Security** and choose **Open Anyway** (only if you trust the release). Homebrew does *not* remove this one-time approval — only Developer ID notarization would (planned for the beta).
- The app lives in the menu bar; enable **launch at login** in Settings if you want it always on. It can **check GitHub for updates** (opt-in — Settings → General → *Automatically check for updates*; a version check only, no usage data is sent), or check on demand from the menu bar.
- Developer ID–signed/notarized downloads are planned for the beta (see [`ROADMAP.md`](ROADMAP.md)).

### Claude Code official limits (optional statusline hook)

Claude Code pipes its official rate limits (the real 5-hour / weekly `used_percentage`) into whatever `statusLine` command you configure. If a hook saves that payload locally, the app shows **provider-reported** limits — no manual token budget needed.

**Easiest: one command.** The `aipet` CLI ships inside the app bundle and installs everything (writes the bundled hook, backs up `settings.json` first, and — if your `statusLine` already points at a **script file** — wraps that script untouched):

```bash
"/Applications/AI Pet Usage.app/Contents/MacOS/aipet" install-hook          # Homebrew / zip install
.build/debug/aipet install-hook                                             # built from source
```

Add `--dry-run` to preview without writing. If your existing `statusLine` is a **compound command** (with pipes/arguments) rather than a single script path, it won't guess — it refuses with guidance and leaves everything unchanged, so you can wrap it manually (see below). It also refuses (changing nothing) on symlinked/dotfiles-managed settings, non-`command` statusLine types, and unmanaged hook references, and prints the revert line after installing.

**Manual alternative** — the same hook lives in the repo at [`Scripts/claude-statusline-hook.sh`](Scripts/claude-statusline-hook.sh) (not in the app bundle — Homebrew users: clone the repo or grab the file from the source zip of a release).

Fresh install (you don't have a custom statusline yet) — add to `~/.claude/settings.json`:

```json
"statusLine": {"type": "command", "command": "/bin/bash /path/to/ai-pet-usage/Scripts/claude-statusline-hook.sh"}
```

**Already have a custom statusline?** Use wrapper mode — your script is **never modified**, and its stdin (the exact original JSON bytes), stdout, stderr, and exit code all pass through untouched:

1. Open `~/.claude/settings.json`, find your current `statusLine.command`, and save that string somewhere (rollback = paste it back).
2. Replace it with the hook wrapping your command:

```json
"statusLine": {"type": "command", "command": "/bin/bash /path/to/ai-pet-usage/Scripts/claude-statusline-hook.sh --wrap /Users/you/.claude/statusline-command.sh"}
```

- The wrap target must be **executable**; for a plain shell script without the executable bit, use `--wrap /bin/bash -- /path/to/script.sh`.
- Extra arguments go after `--`, one per argument (`--wrap /path/to/cmd -- --compact`); compound shell command strings are not accepted.
- What gets persisted is a **frozen allowlist only** — this exact shape, nothing else (session ids, transcript paths, cwd, and any unknown fields are dropped at every level):

```json
{"schema_version": 1, "captured_at": "<UTC ISO8601>",
 "model": {"id": "...", "display_name": "..."},
 "rate_limits": {"five_hour": {"used_percentage": 42, "resets_at": 1789000000},
                 "seven_day":  {"used_percentage": 81, "resets_at": 1789400000}}}
```

- The hook makes **no network requests**; the file stays under `~/Library/Application Support/AIPetUsage/`. A payload without usable `rate_limits` never overwrites the last good file; staleness is judged by the app from the file's mtime.
- Alternative: any other tool that already saves the payload to `~/.claude/usage-status.json` works too — then you don't need this hook at all.

## 🚀 Build & run

```bash
Scripts/swiftpm.sh build                 # build everything
Scripts/swiftpm.sh run usagecore-tests   # run the test suite
Scripts/build-app.sh                     # produce dist/AI Pet Usage.app
open "dist/AI Pet Usage.app"

.build/debug/aipet status                # headless status (CLI)
.build/debug/aipet sprites               # export pixel-pet contact sheets → dist/sprite-preview/
.build/debug/aipet report --out r.html   # headless HTML export
```

> [!IMPORTANT]
> Always build through `Scripts/swiftpm.sh`, not bare `swift build`.

<details>
<summary>Why the wrapper exists (dev-machine CommandLineTools quirks)</summary>

This machine's CommandLineTools installation has two version-mismatch defects (a stale `PackageDescription.private.swiftinterface` and a duplicate `SwiftBridging` modulemap) that the wrapper works around per-invocation without touching system files. A CLT reinstall (`sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install`) makes the workarounds auto-disable. The CLT also lacks XCTest, so tests run as the `usagecore-tests` executable with an XCTest-compatible mini harness.

</details>

## 🗂️ Repository layout

| Path | What lives there |
| --- | --- |
| [`Sources/UsageCore`](Sources/UsageCore) | Provider adapters, ledger, limit engine, pricing, HTML report — no UI dependencies, so the parser logic can be reused by a CLI or Tauri build later. Model prices live in [`model-prices.json`](Sources/UsageCore/Resources/model-prices.json) (sourced & dated per entry; see [`docs/DATA_SOURCES.md`](docs/DATA_SOURCES.md)). |
| [`Sources/PetCore`](Sources/PetCore) | Feeding/XP engine and mood engine — consumes only normalized `UsageCore` state. |
| [`Sources/AIPetUsage`](Sources/AIPetUsage) | The macOS app: menu bar, floating pet panel, the three pages, settings. |
| [`Sources/aipet`](Sources/aipet) | Headless CLI for verification and scripting. |
| [`Sources/usagecore-tests`](Sources/usagecore-tests) | Test suite with synthetic fixtures. |
| [`docs/DATA_SOURCES.md`](docs/DATA_SOURCES.md) | Exactly which local files are read, and why. |

## 🛡️ Privacy — local-first by default

- ✅ Reads only known local usage files or user-configured paths.
- 🚫 Does not upload usage data. Two optional network calls exist, each opt-in and off by default: the update check (Settings → General) asks GitHub for the latest version, and the OpenRouter credits check (Settings → Providers) asks openrouter.ai for your prepaid balance — neither sends usage data.
- 🚫 Does not require account credentials — no app account, no login. (The optional OpenRouter credits monitor reuses the key opencode already stored, only as a request header; the app never asks you for a credential.)
- 💬 Every permission prompt explains why it is needed.
- 🧩 Provider adapters stay isolated, so data-source changes do not affect the pet engine.

See [`PRIVACY.md`](PRIVACY.md) for the promise in plain language and [`docs/DATA_BOUNDARY.md`](docs/DATA_BOUNDARY.md) for the per-data-class checklist of where each thing can (and can't) go.

## ⚙️ Concurrency model (app + CLI)

The app and the `aipet` CLI share `~/Library/Application Support/AIPetUsage/`. This is safe by design:

- CLI `status`/`report` are **read-only by default** — they render the ledger and limit state already on disk (add `--refresh` to rescan provider logs).
- Every writing phase (app refresh, CLI `--refresh`, `reindex`) takes an exclusive interprocess file lock (`refresh.lock`, flock-based). A process that cannot get the lock within 60s skips the write, reports "refresh skipped" in data-quality notes, and serves cached data.
- Before writing, each process converges with the other's progress (ledger reload on size change, per-file max-offset merge of scan state, limit-state reload). Event IDs are content-stable, so any overlap deduplicates instead of double-counting.

## 🧭 Product direction

The app combines two ideas:

1. A lightweight **desktop pet** with engagement mechanics.
2. A **local-first AI usage monitor** for tools such as Codex, Claude Code, Antigravity, Grok Code, and later OpenCode.

The pet makes usage state visible without requiring the user to open dashboards or run commands, reacting to useful signals such as quota remaining, reset windows, token burn rate, stale data, focus sessions, and usage milestones.

The product deliberately avoids a crowded single-page dashboard: usage is separated into the three pages (Today, Limits, Projects), and the HTML report export is part of the alpha scope as a local, offline-readable snapshot of the same data.

### Platform & stack

macOS-first; Windows and Linux are planned as the next platform step after the macOS MVP is stable.

- **SwiftUI + AppKit** for the desktop shell, floating pet window, menu bar, notifications, and launch-at-login.
- **A separate usage core** with provider adapters, so the parser logic can later be reused by a Tauri or CLI version.
- **Local JSON or SQLite storage** for settings, achievements, and daily summaries.

Provider priority: **v1 core** — Codex and Claude Code · **shipped, limited data** — Grok Code (enabled by default; token usage + plan tier; this app does not yet ingest Grok's official limits) · **research** — Antigravity, if a reliable local data source appears · **v2** — OpenCode.

## 📚 Documentation

| Document | Contents |
| --- | --- |
| [`ROADMAP.md`](ROADMAP.md) | Phased delivery plan from product definition through distribution. |
| [`PRIVACY.md`](PRIVACY.md) · [`docs/DATA_BOUNDARY.md`](docs/DATA_BOUNDARY.md) | Privacy promise (plain language) and the per-data-class boundary checklist. |
| [`docs/DATA_SOURCES.md`](docs/DATA_SOURCES.md) | Exact local files read by each provider adapter and the limit-calculation policy. |
| [`docs/HTML_REPORT_EXPORT_SPEC.md`](docs/HTML_REPORT_EXPORT_SPEC.md) | Local static HTML report export requirements. |

## ⚖️ License

Copyright (C) 2026 F-e-u-e-r

This project is licensed under the [GNU AGPL-3.0-only](LICENSE). All code and pixel art (the dog, cat, and bird string-grid sprites) are original to this repository and carry the same license.

The app reads local data files produced by third-party tools (Claude Code, Codex, and Grok CLI session logs and status files). Reading them does not change their respective ownership or terms, and this project never redistributes their contents — everything stays on your machine (see [`docs/DATA_SOURCES.md`](docs/DATA_SOURCES.md)).
