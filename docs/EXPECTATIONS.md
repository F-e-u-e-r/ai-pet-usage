# Expectations

This document captures the expected product behavior for the AI usage desktop pet.

## Product Intent

Build a desktop pet that makes AI usage visible, glanceable, and emotionally engaging.

The app should help a user understand:

- How much AI quota remains.
- Today's AI usage.
- Whether they are burning tokens too quickly.
- When the next reset window arrives.
- Whether local usage data is fresh or stale.
- Whether today has been a healthy usage day.
- Which projects are using the most tokens or cost.

The pet should be useful first and cute second. It should not become a distraction layer on top of work.

## Target User

Primary user:

- Developer or AI-heavy worker using tools such as Codex, Claude Code, Antigravity, Grok Code, and later OpenCode.
- Works in long sessions and wants quota awareness without running commands.
- Cares about privacy and local-first tooling.
- Enjoys lightweight companion UX if it improves awareness.

Secondary user:

- Power user who wants per-project usage, reports, statusline integration, and multi-provider visibility.

## MVP Expectations

The MVP should include:

- A small floating desktop pet.
- A menu-bar or tray app.
- Three focused pages: Today, Limits, and Projects.
- Local usage monitoring for Codex and Claude Code.
- Research support for Antigravity and Grok Code if reliable local data sources are available.
- Clear pet moods based on usage state.
- Dog and cat pet choices.
- Basic feeding engagement.
- Basic notifications for warning thresholds and reset/recovery.
- Local HTML report export.
- Settings for provider selection, refresh interval, pet visibility, and notification thresholds.
- Local-only storage.
- Clear no-data and stale-data states.

The MVP should avoid:

- Cloud accounts.
- Server-side sync.
- Complex inventory systems.
- Voice chat.
- Multiplayer or social features.
- Broad provider support before Codex and Claude Code are stable.
- OpenCode support before the first provider adapter architecture is stable.

## Pet Behavior Expectations

The pet should react to:

- Low usage: relaxed, idle, calm.
- Moderate usage: focused or typing.
- High usage: tired, worried, or slowing down.
- Near quota: visible warning state.
- Quota exhausted: resting or blocked state.
- Quota reset: recovery or celebration state.
- High burn rate: faster motion or nervous behavior.
- Long idle period: sleeping.

The pet should support:

- Dragging to reposition.
- Persistent position.
- Size and opacity settings.
- Pause or hide mode.
- Quiet mode for meetings or focused work.
- Feeding with basic food choices.
- Later levels, skins, and expanded food options.

## AI Usage Expectations

The usage layer should provide a normalized model independent of provider details.

Expected normalized fields:

- Provider name.
- Account or profile identifier when available.
- Project identifier when available.
- Model identifier when available.
- Current session usage percentage.
- Five-hour usage percentage when available.
- Weekly usage percentage when available.
- Reset time.
- Time until reset.
- Token totals when available.
- Estimated cost when available.
- Data freshness.
- Error or no-data reason.

Provider adapters should be isolated. If one provider fails, the rest of the app should keep working.

Limit calculations should be provider-wide or account-wide when the data allows it. A stale idle terminal panel should not be allowed to overwrite a newer aggregate usage value inside the same active limit window.

## Engagement Expectations

Engagement should reinforce useful behavior.

Good engagement examples:

- Daily streak for staying below a configured danger threshold.
- Focus timer that encourages breaks.
- Achievement for finishing a session before hitting quota.
- Gentle reminder when burn rate is unusually high.
- Feeding the pet after useful work sessions.
- Level progression based on real AI activity, with daily caps and healthy-usage bonuses.
- Summary of the day in local report form.
- Exportable HTML report for today's usage or selected project ranges.

Avoid engagement that rewards wasteful usage. Token activity can contribute to XP, but leveling should include caps, cooldowns, or healthy-work modifiers so users are not pushed to burn quota just for unlocks.

## Privacy Expectations

The app should default to local-first behavior.

Expected privacy boundaries:

- No upload of usage data.
- No telemetry in MVP.
- No account credentials required in MVP.
- No broad filesystem crawling.
- Read only documented local paths or user-selected paths.
- Explain every permission prompt before asking.
- Generated HTML reports should be local files and should not include prompts or raw message content by default.

If future features require network access, they should be opt-in and documented.

## Licensing Expectations

The referenced projects should be treated as product and architecture references first.

Direct code reuse must be reviewed case by case:

- MIT-licensed references are easier to reuse with attribution.
- AGPL-licensed references require careful review because redistribution of modified code may impose AGPL obligations.
- Art and animation assets may have separate licenses even when source code is permissive.
- Rewriting, translating, or optimizing another repository's implementation does not automatically avoid license obligations if the new code is derived from the original.
- For MVP, prefer clean-room implementation from product specs instead of source-code-based rewrites.

## Open Decisions

Current decisions:

- Platform: macOS first; Windows and Linux next.
- Provider scope: Codex and Claude Code are required first. Antigravity and Grok Code should be researched for v1 if possible. OpenCode is next step.
- Product depth: start with dog/cat pet, engagement, and feeding; add levels, skins, and food unlocks later.
- Art source: generated images or original placeholder sprites.
- License posture: reference repositories should be used as inspiration/spec input, not copied source, unless license review approves reuse.
- Build posture: scratch implementation from this repository's specs, using reference apps only to extract pros, cons, and feature ideas.
- Provider identity UI: use original colored provider dots plus short codes instead of official logos. This avoids brand/logo licensing risk while staying readable in compact surfaces.

Provider badge mapping:

| Provider | Short code | Dot style |
|---|---:|---|
| Claude Code | `CC` | orange dot |
| Codex | `CX` | blue dot |
| Antigravity | `AG` | rainbow dot |
| Grok Code | `GK` | black/charcoal dot with a light outline for dark mode |

Use the colored dot plus code in menu-bar, pet gauges, dashboard cards, and tables. Use the full provider name in hover/help text, accessibility labels, reports, settings, and onboarding copy.

Still open:

1. Distribution target: private local build, public GitHub release, Homebrew, or app-store-style signed app?
2. First implementation stack: SwiftUI/AppKit first, or Tauri first with macOS as the initial platform?
3. Initial pet art format: sprite sheets, PNG state images, GIF/WebP animations, Live2D, or another format?
4. XP formula: how much weight should raw token activity have versus healthy-use achievements?

## Current Review Backlog

These are the remaining known issues from the latest review pass and should be handled before calling the current MVP public-alpha ready.

1. `Sources/UsageCore/LimitEngine.swift`: Claude fallback still has an edge case. Official Claude readings are treated as usable if any stored window has a future reset; if the 5-hour reading expires and the statusline hook stops for 24h while the weekly window is still future-dated, the 5-hour value can show recovered `0%` instead of falling back to the configured budget estimate.
2. `Sources/AIPetUsage/DashboardViews.swift`: `TokenMixBar` still renders three colored 1px slivers for a zero-token day because the segment widths use `max(1, ...)`.
3. `Sources/AIPetUsage/AppModel.swift`: feed-failure notifications shown while the pet is hidden call `Notifier.post` directly and bypass Quiet Mode / notification settings.
4. `Sources/AIPetUsage/DashboardViews.swift`: the onboarding button says "Open Provider Settings..." but opens Settings generally, not a provider-specific settings tab.

## Definition of Done for MVP

The MVP is done when:

- A user can launch the app and see a floating pet.
- The app can read at least one real AI usage source locally.
- The pet changes state based on usage.
- Warning and reset states are visible.
- Settings persist.
- The app does not upload usage data.
- The user can understand what files are read and why.
