# AI Pet Usage

A macOS desktop pet that reacts to AI usage, quota, token burn, and work rhythm — implemented and running (see **Current Status** below), with the product/planning documents that drove the build kept under `docs/`.

The repo contains both the working app (SwiftPM, `Sources/`) and the specs it was built from: what stays local, how limits are calculated, and how the roadmap is sequenced.

## What Is Stored Here

- `README.md`: repository overview and file map.
- `ROADMAP.md`: phased delivery plan from product definition through distribution.
- `docs/EXPECTATIONS.md`: product expectations, target behavior, non-goals, and open decisions.
- `docs/LICENSING_STRATEGY.md`: clean-room and license-risk policy for using reference repositories.
- `docs/REFERENCE_USAGE_PLAN.md`: how to consolidate ideas from usage-monitor references without merging their source code.
- `docs/MVP_FEATURE_SPEC.md`: first buildable product spec for a scratch implementation.
- `docs/ALPHA_PRODUCT_SPEC.md`: three-page alpha product structure for Today, Limits, and Projects.
- `docs/HTML_REPORT_EXPORT_SPEC.md`: local static HTML report export requirements.
- `docs/DATA_SOURCES.md`: exact local files read by each provider adapter and the limit-calculation policy.
- `docs/PROVIDER_RESEARCH.md`: research checklists and promotion gates for the Antigravity and Grok Code adapters.

## Product Direction

The app should combine two ideas:

1. A lightweight desktop pet with engagement mechanics.
2. A local-first AI usage monitor for tools such as Codex, Claude Code, Antigravity, Grok Code, and later OpenCode.

The pet should make usage state visible without requiring the user to open dashboards or run commands. It should react to useful signals such as quota remaining, reset windows, token burn rate, stale data, focus sessions, and usage milestones.

## Reference Projects

Pet and desktop companion references:

- VPet: deep desktop pet system with animation states, interactions, plugins, and mod support.
- PawPal: pragmatic desktop pet with break reminders, hydration reminders, focus detection, local settings, and Electron/React packaging.
- BongoCat / Bongo-Cat-Mver: input-reactive pet overlay with custom models and simple interaction loops.
- TapBuddy: macOS-native input-reactive floating pet with status-bar controls and custom skins.
- DyberPet: richer pet framework with character state, inventory, tasks, mods, and AI assistant ideas.
- AIRI: larger AI companion direction with realtime voice, memory, avatars, and game/world interaction.

AI usage references:

- usage: local-first Claude Code and Codex quota, token cost, reports, notifications, and usage-driven spirit animation.
- Claude-Code-Usage-Monitor: CLI-first usage analytics, session windows, burn-rate prediction, and companion state output.
- CodexBar: mature provider-adapter model for AI usage, quota, reset windows, and menu-bar monitoring.
- Claude Usage Tracker: native macOS menu-bar app with profiles, threshold alerts, statusline integration, and SwiftUI architecture.

## Recommended First Version

Start with a macOS-first utility. Windows and Linux should be planned as the next platform step after the macOS MVP is stable.

Recommended stack:

- SwiftUI + AppKit for the desktop shell, floating pet window, menu bar, notifications, and launch-at-login.
- A separate usage core with provider adapters so the parser logic can later be reused by a Tauri or CLI version.
- Local JSON or SQLite storage for settings, achievements, and daily summaries.

Initial provider priority:

- v1 core: Codex and Claude Code.
- v1 stretch/research: Antigravity and Grok Code if reliable local data sources are available.
- v2: OpenCode.

## Privacy Position

The app should be local-first by default.

- Read only known local usage files or user-configured paths.
- Do not upload usage data.
- Do not require account credentials for the MVP.
- Make every permission prompt explain why it is needed.
- Keep provider adapters isolated so data-source changes do not affect the pet engine.

## Current Status

**Working MVP implemented.** SwiftUI/AppKit menu-bar app + floating pet + Today/Limits/Projects pages + Codex/Claude Code adapters + local ledger + pricing registry + HTML export + feeding loop, built from scratch against the specs in `docs/`.

### Build & run

```bash
Scripts/swiftpm.sh build              # build everything
Scripts/swiftpm.sh run usagecore-tests  # run the test suite (56 tests)
Scripts/build-app.sh                  # produce dist/AI Pet Usage.app
open "dist/AI Pet Usage.app"
.build/debug/aipet status             # headless status (CLI)
.build/debug/aipet sprites            # export pixel-pet contact sheets → dist/sprite-preview/
.build/debug/aipet report --out r.html  # headless HTML export
```

Always build through `Scripts/swiftpm.sh` (not bare `swift build`): this machine's CommandLineTools installation has two version-mismatch defects (stale `PackageDescription.private.swiftinterface`, duplicate `SwiftBridging` modulemap) that the wrapper works around per-invocation without touching system files. A CLT reinstall (`sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install`) makes the workarounds auto-disable. The CLT also lacks XCTest, so tests run as the `usagecore-tests` executable with an XCTest-compatible mini harness.

### Layout

- `Sources/UsageCore` — provider adapters, ledger, limit engine, pricing, HTML report (no UI dependencies; reusable by CLI/Tauri later). Model prices live in `Sources/UsageCore/Resources/model-prices.json` (sourced & dated per entry; see `docs/DATA_SOURCES.md`).
- `Sources/PetCore` — feeding/XP engine and mood engine (consumes only normalized `UsageCore` state).
- `Sources/AIPetUsage` — the macOS app (menu bar, floating pet panel, three pages, settings).
- `Sources/aipet` — headless CLI for verification and scripting.
- `Sources/usagecore-tests` — test suite with synthetic fixtures.
- `docs/DATA_SOURCES.md` — exactly which local files are read and why.

Settings → General offers **Monitor only (low RAM)** mode: the floating pet window and animations are never created, and the feeding/XP engine is only instantiated in full-pet mode (switching to monitor-only releases it); usage tracking, menu bar, pages, notifications, and export keep working.

### Concurrency model (app + CLI)

The app and the `aipet` CLI share `~/Library/Application Support/AIPetUsage/`. This is safe by design:

- CLI `status`/`report` are **read-only by default** — they render the ledger and limit state already on disk (add `--refresh` to rescan provider logs).
- Every writing phase (app refresh, CLI `--refresh`, `reindex`) takes an exclusive interprocess file lock (`refresh.lock`, flock-based). A process that cannot get the lock within 60s skips the write, reports "refresh skipped" in data-quality notes, and serves cached data.
- Before writing, each process converges with the other's progress (ledger reload on size change, per-file max-offset merge of scan state, limit-state reload). Event IDs are content-stable, so any overlap deduplicates instead of double-counting.

Before asking a coding agent to implement from reference repositories, read `docs/LICENSING_STRATEGY.md`. Rewriting another repository is not a reliable way to avoid license obligations if the new implementation is derived from that code.

The intended approach is feature extraction, not source merging: use reference apps to identify strong product ideas, document those ideas in this repo, and implement the MVP from scratch.

The alpha product should avoid a crowded single-page dashboard. The first usable version should separate usage into three pages: Today, Limits, and Projects.

HTML report export is part of the alpha scope as a local, offline-readable snapshot of Today, Limits, Projects, pricing assumptions, and data-quality notes.
