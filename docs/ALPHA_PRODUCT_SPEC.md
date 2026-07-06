# Alpha Product Spec

This document defines the first alpha product direction based on the current limitations observed in existing usage-monitor apps.

The alpha should be a focused usage product first, with the desktop pet layered on top as a glanceable emotional interface. It should not repeat the mistake of placing every feature on one crowded page.

## Problems to Solve

Current usage-monitor limitations to improve:

- Too many features are stacked on one page, making the product hard to scan.
- 5-hour and weekly limits need to be visible per coding agent.
- Limit calculation should be account-wide or provider-wide, not tied to one terminal panel that may be stale.
- A stale idle terminal can show an older percentage, causing usage to appear to drop from a newer value.
- Project usage is useful, but timeline switching should not be a one-way cycle.
- Daily real-time usage is useful, but estimated cost can be wrong when token counts are not priced against the actual model used.

## Alpha Information Architecture

The alpha app should have three primary pages.

1. Today
2. Limits
3. Projects

The pet remains visible as a small floating companion. The main window provides detailed numbers only when the user opens it.

## Page 1: Today

Purpose: answer "What did I use today?"

Default view should show the current local day from midnight to now.

Primary content:

- Total tokens today.
- Estimated cost today.
- Usage by coding agent.
- Top projects today.
- Current burn rate.
- Last refresh time.
- Data freshness state.
- Pet status summary.

Suggested layout:

- Top summary strip: total usage, estimated cost, burn rate, refresh state.
- Agent cards: Codex, Claude Code, Antigravity, Grok Code if available.
- Project mini-table: top projects by token usage or cost.
- Timeline chart: today by hour.

Required interactions:

- Refresh now.
- Toggle token, cost, and percent views.
- Open agent detail from an agent card.
- Open project detail from a project row.

Alpha acceptance:

- A user can understand today's usage in under 10 seconds.
- Stale or missing data is obvious.
- Cost numbers show which pricing table and model mapping were used.

## Page 2: Limits

Purpose: answer "How much quota remains for each coding agent?"

This page should separate short-window pressure from weekly pressure.

Primary content per coding agent:

- 5-hour limit usage.
- Weekly limit usage.
- Reset countdown for the 5-hour window.
- Reset countdown for the weekly window.
- Current burn rate.
- Projected time to limit at current burn rate.
- Confidence level for the calculation.
- Last source event used.

Suggested layout:

- One row per coding agent.
- Two progress sections per row: 5-hour and weekly.
- Warnings for near-limit, exhausted, stale, and unknown states.

Required agents for alpha:

- Codex
- Claude Code

Research or stretch:

- Antigravity
- Grok Code

Next step:

- OpenCode

## Limit Calculation Strategy

The app should not trust a single terminal panel as the source of truth.

The alpha should use a local usage ledger:

- Scan known provider usage locations.
- Watch known files where practical.
- Import events into a local normalized ledger.
- Deduplicate events by stable identifiers when available.
- Attribute every event to provider, model, project, timestamp, token fields, and source file.
- Compute 5-hour and weekly windows from the ledger.

To handle stale terminal panels:

- Keep a provider-wide aggregate view as the primary display.
- Treat per-terminal or per-panel status as a source event, not as the final truth.
- Do not lower a usage percentage inside the same active limit window just because an older source appears.
- Allow downward correction only after a full reindex or reset-window change, and mark the correction in the UI.
- Show data confidence: high, estimated, stale, or unknown.

Expected internal model:

```text
UsageEvent
- eventId
- providerId
- accountId
- projectId
- modelId
- startedAt
- endedAt
- inputTokens
- outputTokens
- cacheReadTokens
- cacheWriteTokens
- rawCost
- sourcePath
- sourceKind
- importedAt
```

```text
LimitSnapshot
- providerId
- accountId
- fiveHourUsedPercent
- fiveHourResetAt
- weeklyUsedPercent
- weeklyResetAt
- burnRatePerHour
- projectedExhaustionAt
- confidence
- lastEventAt
- warningState
```

## Page 3: Projects

Purpose: answer "Which projects are using my AI quota?"

Primary content:

- Project usage table.
- Token totals by project.
- Estimated cost by project.
- Agent/provider breakdown.
- Model breakdown.
- Time range controls.

Required table columns:

- Project
- Tokens
- Estimated cost
- Agents used
- Top model
- Last active
- Share of selected period

Timeline controls should be user-friendly:

- Today
- Yesterday
- Last 7 days
- This week
- Last week
- Custom range
- Previous and next arrow controls
- Calendar/date picker where supported

Avoid a one-way timeline cycle. Users should be able to move backward, forward, or jump directly to a range.

Alpha acceptance:

- A user can compare projects without changing pages.
- Timeline selection is reversible and direct.
- Project detail can explain which provider/model generated the cost.

## Cost and Model Pricing

The alpha must make cost calculation explicit because model pricing is easy to miscalculate.

Requirements:

- Store a local pricing registry by provider and model.
- Identify the model per usage event whenever possible.
- Price input, output, cache read, and cache write tokens separately when the provider exposes those fields.
- Mark cost as estimated when model identity is missing or token categories are incomplete.
- Let the user override or add model pricing.
- Record pricing version or effective date.
- Show "unknown model" rows instead of silently applying the wrong price.

Expected pricing model:

```text
ModelPrice
- providerId
- modelId
- displayName
- inputPerMillion
- outputPerMillion
- cacheReadPerMillion
- cacheWritePerMillion
- currency
- effectiveFrom
- source
- userOverride
```

Cost display should include:

- Estimated total.
- Pricing confidence.
- Unknown-model count.
- Last pricing update source.

## HTML Report Export

The alpha should include local HTML report export.

The export should generate a static, offline-readable report for today's usage or a selected project time range.

Required report sections:

- Summary of the selected period.
- Usage by coding agent.
- 5-hour and weekly limit status.
- Project usage table.
- Timeline summary.
- Model pricing assumptions.
- Unknown-model and estimated-cost notes.
- Stale-data and parser-error notes.
- Local privacy note.

The report should not include prompts, raw message contents, or full local file paths by default.

Detailed requirements are defined in `docs/HTML_REPORT_EXPORT_SPEC.md`.

## Pet Layer for Alpha

The pet should reflect the three-page product model:

- Today healthy: calm or happy.
- High burn rate: alert or restless.
- Near 5-hour limit: warning state.
- Near weekly limit: tired state.
- Reset occurred: celebration state.
- No data or stale data: confused state.
- Feeding available after useful work: hungry or reward state.

The pet should not replace the usage UI. It should provide a quick emotional signal that invites the user to open the relevant page when needed.

## Alpha Scope

Included:

- macOS app shell.
- Menu-bar entry.
- Floating dog or cat pet.
- Today page.
- Limits page.
- Projects page.
- Codex usage adapter.
- Claude Code usage adapter.
- Local ledger.
- Local pricing registry.
- HTML report export.
- Feeding action.
- Basic settings.

Stretch:

- Antigravity adapter research.
- Grok Code adapter research.
- Scheduled report export.

Excluded:

- OpenCode adapter.
- Windows/Linux builds.
- Cloud sync.
- Account login.
- Telemetry.
- Full inventory system.
- Public skin marketplace.

## Alpha Definition of Done

The alpha is done when:

- A user can launch the macOS app.
- The first page shows today's usage clearly.
- The second page shows 5-hour and weekly limits per supported coding agent.
- The third page shows project usage with direct timeline controls.
- A local HTML report can be exported for today or a selected project range.
- Cost calculation explains model pricing and uncertainty.
- Stale terminal data does not overwrite a newer provider-wide aggregate.
- The pet reacts to today, limit, stale, and reset states.
- All usage data stays local.
