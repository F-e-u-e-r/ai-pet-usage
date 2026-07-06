# HTML Report Export Spec

This document defines the alpha HTML report export feature.

The report should be a local, static, self-contained HTML snapshot of usage data for a selected time range. It should make the app's calculations easy to inspect without requiring the user to keep the app open.

## Product Goal

HTML export should answer:

- What did I use during this period?
- Which coding agents consumed quota?
- How close was I to 5-hour and weekly limits?
- Which projects used the most tokens or cost?
- Which model pricing assumptions were used?
- Which numbers are exact, estimated, stale, or unknown?

The report should complement the app UI. It should not become a replacement for the Today, Limits, and Projects pages.

## Export Entry Points

The user should be able to export from:

- Today page: export today's report.
- Limits page: export current limit snapshot.
- Projects page: export selected project time range.
- Menu bar: export quick daily report.

## Report Types

Alpha should support:

- Daily report: current local day from midnight to now.
- Selected range report: user-selected project range where available.

Later:

- Weekly report.
- Monthly report.
- Scheduled report.
- Markdown or CSV companion export.

## Report Content

Required sections:

- Header: report title, selected time range, generated time, timezone.
- Executive summary: total tokens, estimated cost, active agents, active projects, burn rate.
- Agent usage: usage by Codex, Claude Code, and any available research providers.
- Limit status: 5-hour and weekly usage, reset countdowns, confidence, warning state.
- Project usage: project table with tokens, estimated cost, agents used, top model, last active.
- Timeline: usage over the selected period.
- Pricing notes: pricing registry version, model mapping, unknown models, user overrides.
- Data quality notes: stale data, missing fields, estimated values, parser errors.
- Privacy note: confirms the report was generated locally.

Optional sections:

- Pet summary: pet mood and feeding state for the selected period.
- Achievements or healthy-usage notes.
- Raw event appendix behind a collapsed section.

## Data Safety

Default report should avoid exposing unnecessary sensitive data.

Defaults:

- Do not include raw prompts.
- Do not include message contents.
- Do not include full local file paths unless the user enables a detailed export.
- Show project names, provider names, model names, token counts, costs, timestamps, and confidence states.
- Include a visible label when project names or paths are redacted.

Detailed export can be added later with explicit user confirmation.

## HTML Requirements

The alpha report should be:

- Static HTML.
- Viewable offline.
- Self-contained when practical.
- Printable.
- Usable in light and dark mode.
- Readable without JavaScript where practical.

The report may include embedded CSS. Avoid external CDN dependencies so the report works offline and does not leak usage metadata.

## Cost Transparency

Every report must explain cost confidence.

The pricing section should show:

- Provider.
- Model.
- Input price.
- Output price.
- Cache read price when available.
- Cache write price when available.
- Currency.
- Pricing source.
- Effective date.
- Whether the price is a user override.

If model identity is missing:

- Do not silently apply a default model price.
- Mark the row as unknown model.
- Exclude it from exact cost totals or include it only in estimated totals.

## Alpha Acceptance Criteria

HTML export is acceptable when:

- A user can export today's report from the Today page.
- A user can export the current selected range from the Projects page.
- The report includes Today, Limits, Projects, pricing, and data-quality sections.
- The report is viewable offline.
- The report does not include prompts or raw message content by default.
- The report clearly marks estimated, stale, and unknown-model values.
- The report is generated locally.
