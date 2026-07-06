# MVP Feature Spec

This document defines the first buildable version of the AI pet usage app.

The MVP should be built from scratch. Reference repositories can inform the product direction, but implementation should come from this spec and original code.

## Product Goal

Create a macOS-first desktop pet that makes AI usage visible, emotionally understandable, and gently engaging.

The pet should improve on a plain usage monitor by making quota pressure, reset timing, burn rate, and daily AI work rhythm visible without requiring the user to open a dashboard or run a command.

The alpha UI structure is defined in `docs/ALPHA_PRODUCT_SPEC.md`. The MVP should follow that structure unless implementation constraints force a smaller first slice.

## Reference Feature Merge

The project should merge the best feature ideas from usage-monitor and desktop-pet references, not their source code.

Useful feature ideas to absorb:

- Always-visible usage status.
- Local-first usage parsing.
- Session and weekly quota awareness.
- Reset countdowns.
- Burn-rate warnings.
- Cost and token estimates.
- No-data and stale-data states.
- Per-provider adapter boundaries.
- HTML report export.
- Quiet threshold notifications.
- Pet mood changes based on usage.
- Feeding and engagement loops.
- Unlockable skins and food options.

Do not copy:

- Source files.
- Parser implementation details.
- UI text.
- Icons.
- Pet assets.
- Screenshots.
- Animation frames.

## MVP Providers

Required:

- Codex
- Claude Code

Research or stretch:

- Antigravity
- Grok Code

Next step:

- OpenCode

## Desktop Pet

MVP pet requirements:

- Dog and cat options.
- Floating transparent window.
- Always-on-top behavior.
- Draggable position.
- Persistent position and size.
- Menu-bar controls.
- Show, hide, pause, and quiet mode.
- Basic generated or placeholder art.

Required states:

- Idle
- Focused
- Hungry
- Eating
- Happy
- Tired
- Warning
- Exhausted
- Sleeping
- Reset celebration

## Usage Display

The app should show:

- Today's usage as the first page.
- 5-hour and weekly limits as the second page.
- Project usage as the third page.
- HTML export for today's report and selected project ranges.
- Provider status.
- Current session usage percentage.
- Weekly usage percentage where available.
- Reset countdown.
- Token totals where available.
- Estimated cost where available.
- Last refreshed time.
- Data-source explanation.
- No-data guidance.
- Stale-data warning.

The pet should communicate the same information through behavior:

- Low usage: calm idle.
- Moderate usage: focused.
- High usage: tired.
- Near quota: warning.
- Exhausted: blocked/resting.
- Reset: happy celebration.
- High burn rate: more anxious or faster animation.

## Feeding and Engagement

The MVP should include a small feeding loop.

Required:

- Feed action from menu or pet interaction.
- A few starter food items.
- Hunger or satisfaction state.
- Food reward after useful work sessions.
- Simple daily activity summary.

Later:

- Level system.
- More food choices.
- Skin unlocks.
- Pet accessories.
- Multiple personalities.

XP should not reward raw token burning without guardrails. Token activity can contribute to XP, but the formula should include daily caps, cooldowns, and healthy-usage bonuses.

## Usage Core Architecture

The app should use provider adapters.

Each adapter should:

- Detect whether the provider exists locally.
- Explain what local files or settings it reads.
- Refresh usage data without blocking the UI.
- Return a normalized usage snapshot.
- Fail independently without breaking the pet.

Normalized snapshot fields:

- `providerId`
- `displayName`
- `status`
- `sessionUsagePercent`
- `weeklyUsagePercent`
- `resetAt`
- `updatedAt`
- `tokenInput`
- `tokenOutput`
- `tokenCache`
- `estimatedCost`
- `sourceDescription`
- `errorMessage`

## Privacy Requirements

MVP privacy rules:

- No usage data upload.
- No server-side sync.
- No telemetry.
- No account credentials required.
- No broad filesystem crawling.
- Read only known documented paths or user-selected paths.
- Permission prompts must explain why they are needed before asking.
- HTML reports should be generated locally and should not include prompts or raw message content by default.

## Better Than Current Usage App

The MVP should be better than a plain usage monitor in these ways:

- Three focused pages instead of a single crowded page.
- Provider-wide limit calculation instead of trusting a stale terminal panel.
- Direct timeline controls for project usage.
- Model-aware cost calculation.
- Local HTML report export with pricing and data-quality notes.
- More understandable at a glance through pet state.
- Less dashboard-focused.
- More engaging through feeding and pet progression.
- Cleaner provider adapter boundary.
- Clearer onboarding for missing/stale data.
- User-controlled noise level.
- Built from a product spec rather than accumulated scripts.

## Out of Scope for MVP

- Cloud sync.
- Voice chat.
- Full inventory system.
- Marketplace or workshop.
- Complex mod system.
- Team dashboards.
- OpenCode support before adapter architecture is stable.
- Windows/Linux desktop builds.

## Acceptance Criteria

The MVP is acceptable when:

- A user can install and launch the macOS app.
- A floating dog or cat appears on the desktop.
- The app reads Codex and Claude Code usage locally.
- The app separates Today, Limits, and Projects into focused views.
- The pet changes state based on real usage.
- The app shows reset timing and warning states.
- The app explains cost pricing confidence.
- The app can export a local HTML report.
- The user can feed the pet.
- Settings persist.
- The app explains what local data it reads.
- No usage data is uploaded.
