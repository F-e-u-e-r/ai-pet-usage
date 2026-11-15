# Checks (ground-truth gates)

```bash
bash checks/run-all.sh
```

## Pre-commit (macOS widget work)

```bash
# Executable gates only
bash checks/precommit-review-gate.sh

# + dual-family review authority (gpt-6.1-sol + grok-4.6)
PRE_COMMIT_REVIEW=1 bash checks/precommit-review-gate.sh

# Optional panel ratings (non-authoritative): codex, agy, grok, opencode, nim, typesafe
PANEL_REVIEW=1 PRE_COMMIT_REVIEW=1 bash checks/precommit-review-gate.sh
```

**Panel vs gate:** only **sol** and **grok** lines can block a commit when `PRE_COMMIT_REVIEW=1`.  
Nim and TypeSafe AI are listed for future adapter work; they are not app providers yet.

## macOS widget

Handoff for upstream: **`docs/macOS_WIDGET_HANDOFF.md`**.

- Snapshot: `UsageCore/WidgetSnapshot.swift` → `widget-snapshot.json` (App Support + `/Users/Shared/AIPetUsage/` + App Group when available).
- UI: `macOS/AIPetUsageWidget.xcodeproj` + `Extensions/AIPetUsageWidget/` (embedded by `Scripts/build-app.sh`).
- **Xcode.app** is used automatically via `Scripts/swiftpm.sh` (`DEVELOPER_DIR`).
- **No paid account:** ad-hoc sandboxed appex + Shared mirror (see handoff doc). **`DEVELOPMENT_TEAM=…`** enables prod entitlements + App Group (maintainer path).
- Providers on the widget: **Codex**, **Antigravity**, **Grok**, **OpenCode**, plus Claude chrome rows when present.