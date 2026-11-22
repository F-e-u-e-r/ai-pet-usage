# macOS desktop widget

A WidgetKit extension (small, medium, large) that shows each provider's limits on the desktop and in Notification Center. Ad‑hoc builds work for personal use; distributing it to others needs a **paid or Personal Team** Apple Developer account, because **proper signing is the path of least pain** for gallery + data.

## Where it lives

| Piece | Location |
|--------|-----------|
| Snapshot model + I/O | `Sources/UsageCore/WidgetSnapshot.swift` |
| App publish hook | `Sources/AIPetUsage/WidgetSnapshotPublisher.swift` → `AppModel.publishWidgetSnapshot()` after refresh |
| WidgetKit UI | `Extensions/AIPetUsageWidget/` |
| Xcode extension target | `macOS/AIPetUsageWidget.xcodeproj` (tracked in git; `.gitignore` waives `*.xcodeproj` only for this path) |
| Install + PlugInKit | `Scripts/install-local-app.sh`, `Scripts/register-widget.sh` |
| Golden gate | `checks/widget-golden/` |
| Entitlements (prod) | `Extensions/AIPetUsageWidget/AIPetUsageWidget.entitlements` — **sandbox + App Group** |
| Entitlements (adhoc) | `Extensions/AIPetUsageWidget/AIPetUsageWidget.adhoc.entitlements` — **sandbox + `/Users/Shared/AIPetUsage/` read** |
| Main app App Group | `Extensions/AIPetUsage/AIPetUsage.entitlements` — `group.dev.aipetusage.app` |

**Widget providers (chrome rows):** Codex, Claude (+ Fable when present), Antigravity buckets, Grok, OpenCode (when enabled), Cursor ("Cursor" and "Cursor Other" rows; monthly plan % shown in the weekly column). Data is **limit % + today tokens/cost** only (no prompts).

**Stale weekly values:** a weekly reading older than 30 minutes (Claude, Antigravity, Cursor) is drawn at 0.55 opacity and its VoiceOver label adds the age ("as of 10h ago"), matching the menu bar.

## Data path (contract)

1. Main app builds `WidgetSnapshot` from dashboard + `ProviderLimitState` (`WidgetSnapshotBuilder`).
2. Writes **`widget-snapshot.json`** to:
   - `~/Library/Application Support/AIPetUsage/` (always)
   - `/Users/Shared/AIPetUsage/<uid>/widget-snapshot.json` (0600 mirror for sandboxed ad‑hoc appex)
   - App Group container when `containerURL(forSecurityApplicationGroupIdentifier:)` works
3. Calls `WidgetCenter.shared.reloadTimelines(ofKind: "ProviderUsageWidget")`.

**Widget read order (extension):** App Group (if any) → **shared mirror** → App Support (only when extension is **not** sandboxed — do not rely on this for shipping).

## Build matrix

| Environment | Widget entitlements | Snapshot source | PlugInKit |
|-------------|---------------------|-----------------|-----------|
| **Ad‑hoc** (`DEVELOPMENT_TEAM` unset) | `AIPetUsageWidget.adhoc.entitlements` | **`/Users/Shared/AIPetUsage/<uid>/widget-snapshot.json`** | `Scripts/install-local-app.sh` (promotes shared root to `root:wheel` + `01777` when possible) |
| **Personal Team / Dev ID** | `AIPetUsageWidget.entitlements` + same team on app | **App Group** `group.dev.aipetusage.app` | Normal discovery once app is signed |

```bash
# Ad-hoc (no paid account)
Scripts/build-app.sh          # embeds widget
Scripts/install-local-app.sh  # /Applications + register
open "/Applications/AI Pet Usage.app"

# With Apple Developer team (recommended for maintainer)
export DEVELOPMENT_TEAM=XXXXXXXXXX
Scripts/build-app.sh
# Wire signing in Xcode for main app + appex; drop reliance on Shared temp exception if group works.
```

## Before distributing signed builds (needs a Developer account)

1. **Single team ID** on **main app binary** and **widget appex** (`CODE_SIGN_ENTITLEMENTS` already point at prod plist when `DEVELOPMENT_TEAM` is set in `build-widget-extension.sh`).
2. **Confirm App Group** `group.dev.aipetusage.app` in the Apple Developer portal for that team; register to provisioning profiles.
3. **Remove or gate** `temporary-exception.files.absolute-path.read-only` for Shared once App Group is verified on maintainer hardware.
4. **`Product > Archive`** / notarized path if distributing outside git clones.
5. **CI:** `bash checks/widget-golden/run.sh` + `Scripts/build-widget-extension.sh` on a macOS runner with **Xcode.app** (not CLT-only).

## Known ad‑hoc pitfalls (documented so you don’t re-debug)

| Symptom | Cause | Fix |
|---------|--------|-----|
| Widget **missing from gallery** | Appex built with **no App Sandbox** (empty entitlements) | Use adhoc plist **with** `com.apple.security.app-sandbox` |
| Widget **empty** but app has data | Sandboxed appex reading its **own** App Support, not host’s | Shared mirror + read order in `WidgetSnapshotStore.read(from: .widgetExtension)` |
| `pluginkit -m` shows **no matches** | Stale plugin path or failed `-a` | `Scripts/register-widget.sh` (removes duplicates, fails loud on `-a`) |
| Gallery stale after install | pkd cache | `killall pkd; killall NotificationCenter` after install |

## Antigravity / network (related UX)

Official `agy /usage` quota is **off by default** (`AppSettings.antigravityQuotaEnabled`) so refresh does not spawn OAuth. Transcript usage stays local. See `docs/DATA_SOURCES.md`.

## Tests

- `Sources/usagecore-tests/WidgetSnapshotTests.swift` (+ suite in `main.swift`)
- `checks/widget-golden/cases.jsonl` — row filter / provider order

## Release checklist

- [ ] `Scripts/build-app.sh` embeds `AIPetUsageWidgetExtension.appex`
- [ ] Install to `/Applications`, `pluginkit -m -i dev.aipetusage.app.widget` shows **`+`** and correct path
- [ ] Widget shows **non-empty rows** within 1 refresh of opening app
- [ ] With **team signing only**: snapshot file appears in group container and widget works **without** `/Users/Shared` mirror (optional hardening PR)

## Out of scope

- App Store metadata, widget family screenshots
- Paid-account automatic CI signing secrets (maintainer supplies `DEVELOPMENT_TEAM` in secure CI vars)