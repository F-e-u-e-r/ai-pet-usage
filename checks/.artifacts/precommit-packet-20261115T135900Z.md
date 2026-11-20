# Pre-commit packet (AI Pet Usage)

## Scope
WidgetKit macOS widget + WidgetSnapshot pipeline (Codex / Antigravity / Grok / OpenCode).

## Ground truth
- checks/run-all.sh: GREEN (this run)

## Changed files (sample)
```
README.md
Scripts/claude-statusline-hook.sh
Scripts/test-claude-statusline-hook.sh
Sources/AIPetUsage/AIPetUsageApp.swift
Sources/AIPetUsage/AppModel.swift
Sources/AIPetUsage/AppSettings.swift
Sources/AIPetUsage/DashboardViews.swift
Sources/AIPetUsage/MenuBarBadge.swift
Sources/AIPetUsage/MenuBarPanel.swift
Sources/AIPetUsage/PetPanel.swift
Sources/AIPetUsage/SettingsViews.swift
Sources/AIPetUsage/Theme.swift
Sources/PetCore/PixelArt.swift
Sources/PetCore/ProviderBrand.swift
Sources/PetCore/UsageRingModel.swift
Sources/UsageCore/ClaudeCodeAdapter.swift
Sources/UsageCore/DiagnosticReport.swift
Sources/UsageCore/GrokCodeAdapter.swift
Sources/UsageCore/GrokQuota.swift
Sources/UsageCore/JSONLScanner.swift
Sources/UsageCore/LimitEngine.swift
Sources/UsageCore/Models.swift
Sources/UsageCore/PrivacyRedaction.swift
Sources/UsageCore/Resources/model-prices.json
Sources/UsageCore/StatusRenderer.swift
Sources/UsageCore/StatuslineHookScript.swift
Sources/UsageCore/UsageCoordinator.swift
Sources/UsageCore/UsageLedger.swift
Sources/usagecore-tests/CanonicalLedgerTests.swift
Sources/usagecore-tests/GrokQuotaTests.swift
Sources/usagecore-tests/PetCoreTests.swift
Sources/usagecore-tests/PixelArtTests.swift
Sources/usagecore-tests/ReportedLimitFieldTests.swift
Sources/usagecore-tests/Tests.swift
Sources/usagecore-tests/main.swift
docs/ADAPTER_CONTRACT.md
docs/DATA_SOURCES.md
```

## Diff stat
```
 README.md                                          |   2 +-
 Scripts/claude-statusline-hook.sh                  |  73 ++-
 Scripts/test-claude-statusline-hook.sh             |  36 ++
 Sources/AIPetUsage/AIPetUsageApp.swift             |  11 +-
 Sources/AIPetUsage/AppModel.swift                  | 187 +++++++-
 Sources/AIPetUsage/AppSettings.swift               |  77 ++++
 Sources/AIPetUsage/DashboardViews.swift            | 312 ++++++++++++-
 Sources/AIPetUsage/MenuBarBadge.swift              |  12 +-
 Sources/AIPetUsage/MenuBarPanel.swift              | 114 ++++-
 Sources/AIPetUsage/PetPanel.swift                  |  40 +-
 Sources/AIPetUsage/SettingsViews.swift             | 185 +++++++-
 Sources/AIPetUsage/Theme.swift                     | 140 +++++-
 Sources/PetCore/PixelArt.swift                     |   4 +
 Sources/PetCore/ProviderBrand.swift                |  44 +-
 Sources/PetCore/UsageRingModel.swift               |  31 +-
 Sources/UsageCore/ClaudeCodeAdapter.swift          |  81 +++-
 Sources/UsageCore/DiagnosticReport.swift           |   4 +
 Sources/UsageCore/GrokCodeAdapter.swift            |  72 ++-
 Sources/UsageCore/GrokQuota.swift                  |  69 ++-
 Sources/UsageCore/JSONLScanner.swift               |   7 +-
 Sources/UsageCore/LimitEngine.swift                |   2 +-
 Sources/UsageCore/Models.swift                     |  53 ++-
 Sources/UsageCore/PrivacyRedaction.swift           |   3 +-
 Sources/UsageCore/Resources/model-prices.json      |  14 +
 Sources/UsageCore/StatusRenderer.swift             |   9 +
 Sources/UsageCore/StatuslineHookScript.swift       | 502 +++++++++++----------
 Sources/UsageCore/UsageCoordinator.swift           |  72 ++-
 Sources/UsageCore/UsageLedger.swift                |   2 +-
 Sources/usagecore-tests/CanonicalLedgerTests.swift |   9 +-
 Sources/usagecore-tests/GrokQuotaTests.swift       |  52 ++-
 Sources/usagecore-tests/PetCoreTests.swift         |  20 +-
 Sources/usagecore-tests/PixelArtTests.swift        |  50 +-
 .../usagecore-tests/ReportedLimitFieldTests.swift  |  23 +-
 Sources/usagecore-tests/Tests.swift                | 403 ++++++++++++++++-
 Sources/usagecore-tests/main.swift                 |  55 ++-
 docs/ADAPTER_CONTRACT.md                           |   1 +
 docs/DATA_SOURCES.md                               |  67 ++-
 37 files changed, 2424 insertions(+), 414 deletions(-)
```

## Review contract
Respond with exactly one line first: `PROCEED` or `FIX`.
Then list findings as `(reviewer, F#): claim — evidence — severity`.

### Static findings (machine)
- F1: Widget snapshot must stay share-safe (no paths / secrets in JSON).
- F2: App Group `group.dev.aipetusage.app` required for sandboxed widget extension.
- F3: Nim and TypeSafe AI are **not** wired as providers; widget order documents Codex/AG/Grok/OC only.
- F4: Widget extension requires Xcode project build (Extensions/AIPetUsageWidget); SKIP_WIDGET=1 in project gate until embedded.

## Gate reviewers (authority)
- **gpt-6.1-sol** (codex family)
- **grok-4.6** (xAI)

Panel raters (non-authoritative when PANEL_REVIEW=1): codex, agy, grok, opencode, nim, typesafe.
