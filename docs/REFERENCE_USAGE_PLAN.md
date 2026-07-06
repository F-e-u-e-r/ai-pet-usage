# Reference Usage Plan

This document explains how this project should consolidate ideas from existing AI usage-monitor repositories without merging their source code.

## Goal

Create one original usage-monitor specification for the desktop pet.

The output should combine useful ideas from:

- `usage`
- `Claude-Code-Usage-Monitor`
- `CodexBar`
- `Claude-Usage-Tracker`

The implementation should be original code written from this project's specification.

"Merge" means merging strengths and feature ideas into this project's product spec. It does not mean merging repositories, source directories, parser code, UI code, or assets.

## Provider Priority

v1 core:

- Codex
- Claude Code

v1 research or stretch:

- Antigravity
- Grok Code

v2:

- OpenCode

Later:

- OpenAI API
- Anthropic API
- Cursor
- Gemini
- OpenRouter
- LiteLLM

## Features to Consolidate Into the Spec

From usage-monitor references:

- Menu-bar or always-visible usage status.
- Session quota percentage.
- Weekly quota percentage where available.
- Reset countdowns.
- Local log parsing.
- Statusline or hook-based refresh where needed.
- Token totals and estimated cost.
- Burn-rate detection.
- Threshold notifications.
- Stale-data and no-data handling.
- Per-project summaries.
- HTML report export.
- Provider adapter architecture.

From pet references:

- Pet mood changes based on usage.
- Small animated companion near the user's work area.
- Feeding and engagement loops.
- Unlockable skins and food options.
- Quiet defaults and user-controlled intensity.

## Clean Implementation Boundary

Allowed:

- Reading public README files, docs, screenshots, and behavior descriptions.
- Writing original requirements in this repository.
- Implementing provider adapters from documented local file formats or observed user-owned local data.
- Using standard OS APIs and project-approved dependencies.

Not allowed without license review:

- Copying source files.
- Translating code from one language to another.
- Asking a coding agent to rewrite a repository.
- Asking a coding agent to optimize an existing AGPL implementation into this project.
- Copying parser logic line-by-line.
- Copying assets, icons, pet frames, screenshots, or UI text.

## Scratch MVP Policy

The MVP should be implemented from zero using this repository's planning documents:

- `docs/MVP_FEATURE_SPEC.md`
- `docs/EXPECTATIONS.md`
- `docs/REFERENCE_USAGE_PLAN.md`
- `docs/LICENSING_STRATEGY.md`

Reference apps can be used to identify what is useful, what is missing, and what feels poor in practice. They should not be treated as implementation bases.

## Adapter Design

Every provider adapter should implement the same conceptual interface:

```text
ProviderAdapter
- providerId
- displayName
- detectAvailability()
- refreshUsage()
- explainDataSources()
- explainRequiredPermissions()
```

Each refresh should return a normalized usage snapshot:

```text
UsageSnapshot
- providerId
- status: unavailable | noData | stale | healthy | warning | exhausted | error
- sessionUsagePercent
- weeklyUsagePercent
- tokenInput
- tokenOutput
- tokenCache
- estimatedCost
- resetAt
- updatedAt
- sourceDescription
- errorMessage
```

The pet engine should consume only `UsageSnapshot` data. It should not know provider-specific file paths or parsing details.

## Licensing Note

Free distribution does not remove license obligations.

If the project copies AGPL code, the resulting app may need to comply with AGPL obligations. For MVP, use AGPL projects as product references only.
