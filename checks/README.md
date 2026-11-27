# Checks (ground-truth gates)

```bash
bash checks/run-all.sh
```

## Pre-commit (macOS widget work)

```bash
# Executable gates only
bash checks/precommit-review-gate.sh

# + dual-family review authority (gpt-6.1-sol + grok-4.7)
PRE_COMMIT_REVIEW=1 bash checks/precommit-review-gate.sh

# Optional panel ratings (non-authoritative): codex, agy, grok, opencode, nim, typesafe
PANEL_REVIEW=1 PRE_COMMIT_REVIEW=1 bash checks/precommit-review-gate.sh
```

**Panel vs gate:** only **sol** and **grok-4.7** lines can block a commit when `PRE_COMMIT_REVIEW=1`.  
Nim and TypeSafe AI are listed for future adapter work; they are not app providers yet.

**Env**

- `PRE_COMMIT_BASE_REF` — diff base for the findings packet (default `origin/main`; uses `BASE...HEAD`, not empty worktree).
- `PRE_COMMIT_DIFF_LINES` — max unified-diff lines embedded in the packet (default `500`).
- `SKIP_USAGE_TESTS_RUN=0` — run full `usagecore-tests` inside Phase 1 (default `1` in this script for CLT speed).
- `DISPATCH_PY` — path to `~/.claude/lib/dispatch.py` (requires `--prompt-file` + `--outdir`; script passes these).
- `PRE_COMMIT_GROK_MODEL` — xAI gate/panel model (default `grok-4.7`).
- `DISPATCH_TIMEOUT` — seconds per reviewer (default `900`).
- Panel **typesafe** uses the **nim** dispatch tool with a TypeSafe-lens prompt (no separate CLI).

## macOS widget

Handoff for upstream: **`docs/macOS_WIDGET_HANDOFF.md`**.

- Snapshot: `UsageCore/WidgetSnapshot.swift` → `widget-snapshot.json` (App Support + `/Users/Shared/AIPetUsage/` + App Group when available).
- UI: `macOS/AIPetUsageWidget.xcodeproj` + `Extensions/AIPetUsageWidget/` (embedded by `Scripts/build-app.sh`).
- **Xcode.app** is used automatically via `Scripts/swiftpm.sh` (`DEVELOPER_DIR`).
- **No paid account:** ad-hoc sandboxed appex + Shared mirror (see handoff doc). **`DEVELOPMENT_TEAM=…`** enables prod entitlements + App Group (maintainer path).
- Providers on the widget: **Codex**, **Antigravity**, **Grok**, **OpenCode**, plus Claude chrome rows when present.