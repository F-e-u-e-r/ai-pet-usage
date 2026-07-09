<div align="center">

# 🐾 AI Pet Usage

**A macOS desktop pet that reacts to AI usage — quota, token burn, cost, and work rhythm.**

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![Swift 5](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)
![SwiftUI + AppKit](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-6E4AFF)
![Local-first](https://img.shields.io/badge/privacy-local--first-2EA043)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

Your AI usage becomes a living companion — no dashboards to open, no commands to run.

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
- 🔌 **Provider adapters** — Codex and Claude Code today; Antigravity and Grok Code behind research gates; OpenCode planned next.
- 🧮 **Local ledger + limit engine** — quota, reset windows, token burn rate, and per-model costs from a pricing registry that is sourced & dated per entry.
- 🐕 **Feeding/XP loop and mood engine** — the pet reacts to signals such as quota remaining, burn rate, stale data, focus sessions, and usage milestones.
- 📄 **Offline HTML report export** — a local, offline-readable snapshot of Today, Limits, Projects, pricing assumptions, and data-quality notes.
- 👀 **Live updates & scheduled exports** — FSEvents file-watching keeps data fresh; report export can run on a schedule.
- 🪶 **Monitor-only (low RAM) mode** — Settings → General: the floating pet window and animations are never created, and the feeding/XP engine is only instantiated in full-pet mode (switching to monitor-only releases it); usage tracking, menu bar, pages, notifications, and export keep working.
- ⌨️ **Headless `aipet` CLI** — status, reports, and sprite export from the terminal.

## 🚀 Build & run

```bash
Scripts/swiftpm.sh build                 # build everything
Scripts/swiftpm.sh run usagecore-tests   # run the test suite (69 tests)
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
- 🚫 Does not upload usage data.
- 🚫 Does not require account credentials.
- 💬 Every permission prompt explains why it is needed.
- 🧩 Provider adapters stay isolated, so data-source changes do not affect the pet engine.

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

Provider priority: **v1 core** — Codex and Claude Code · **v1 stretch/research** — Antigravity and Grok Code, if reliable local data sources are available · **v2** — OpenCode.

## 📚 Documentation

| Document | Contents |
| --- | --- |
| [`ROADMAP.md`](ROADMAP.md) | Phased delivery plan from product definition through distribution. |
| [`docs/DATA_SOURCES.md`](docs/DATA_SOURCES.md) | Exact local files read by each provider adapter and the limit-calculation policy. |
| [`docs/HTML_REPORT_EXPORT_SPEC.md`](docs/HTML_REPORT_EXPORT_SPEC.md) | Local static HTML report export requirements. |

## ⚖️ License

Copyright (C) 2026 F-e-u-e-r

This project is licensed under the [GNU AGPL-3.0](LICENSE). All code and pixel art are original to this repository.
