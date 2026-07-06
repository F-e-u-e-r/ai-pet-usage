# Roadmap

This roadmap assumes a macOS-first app that combines a floating desktop pet with local AI usage monitoring. Windows and Linux are planned after the macOS MVP is stable.

## Phase 0: Product Definition

Goal: lock the first product slice before building.

Deliverables:

- Confirm first platform: macOS only, or cross-platform.
- Confirm first AI sources and provider priority.
- Choose pet style and initial pet species.
- Define privacy policy and local data-source boundary.
- Select initial pet states and usage signals.
- Decide whether any referenced code can be reused based on license compatibility.
- Adopt the clean-room workflow in `docs/LICENSING_STRATEGY.md` for any feature inspired by copyleft or unclear sources.
- Finalize the scratch MVP scope in `docs/MVP_FEATURE_SPEC.md`.
- Finalize the alpha information architecture in `docs/ALPHA_PRODUCT_SPEC.md`.

Acceptance criteria:

- `docs/EXPECTATIONS.md` has no blocking open questions.
- MVP feature list is short enough to build in one focused pass.
- Technical stack is selected.

## Phase 1: Desktop Pet Prototype

Goal: prove the pet can live comfortably on the desktop.

Deliverables:

- Transparent always-on-top floating pet window.
- Draggable position.
- Menu-bar or tray control surface.
- Dog and cat pet options, using original/generated placeholder assets.
- Idle, active, sleeping, warning, and celebration states.
- Basic settings: show/hide, opacity, size, start at login, click-through toggle.

Acceptance criteria:

- Pet can run for a full work session without getting in the way.
- Pet position and settings persist across restarts.
- No AI usage parsing is required yet.

## Phase 2: Usage Core

Goal: normalize AI usage data into a stable internal model.

Deliverables:

- Codex local usage adapter.
- Claude Code local usage adapter or statusline hook.
- Local usage ledger that aggregates provider-wide data instead of trusting one terminal panel.
- Model-aware pricing registry for estimated costs.
- Local HTML report generation from normalized usage data.
- Antigravity local data-source research.
- Grok Code local data-source research.
- Normalized usage model with session usage, weekly usage, reset time, cost estimate, stale state, and no-data state.
- Parser tests with fixture files.
- Clear onboarding for missing local data.

Acceptance criteria:

- Usage data can be refreshed without blocking the UI.
- Parser failures are isolated per provider.
- The UI can display reliable no-data, stale-data, healthy, warning, and exhausted states.
- Usage percentage should not appear to drop inside the same active limit window because an older terminal panel reported stale state.

## Phase 3: Pet and Usage Integration

Goal: make the pet meaningfully react to usage.

Deliverables:

- Three main usage pages: Today, Limits, and Projects.
- Export controls for today's report and selected project ranges.
- Mapping from usage state to pet mood.
- Burn-rate-driven animation intensity.
- Threshold alerts at configurable levels.
- Reset/recovery animation.
- Provider-specific pet reactions for Codex and Claude Code.
- Experimental provider-specific reactions for Antigravity and Grok Code if adapters are stable.

Acceptance criteria:

- The pet communicates quota status at a glance.
- Today usage, limit pressure, and project usage are separated into focused views.
- Exported HTML reports include usage, limits, projects, pricing, and data-quality notes.
- Notifications are useful but quiet by default.
- Users can reduce or disable animation intensity.

## Phase 4: Engagement Loop

Goal: create lightweight habits without making the app noisy.

Deliverables:

- Focus session timer.
- Break reminders.
- Feeding loop with food items unlocked over time.
- Daily healthy-usage streak.
- Small achievements for usage discipline.
- Token-activity-based XP with daily caps, so unlocks reflect real work without encouraging wasteful quota use.
- Optional end-of-day summary.

Acceptance criteria:

- Engagement features can be disabled independently.
- Rewards are tied to useful behavior, not raw token consumption.
- The pet feels helpful during work, not distracting.

## Phase 5: Reports and Power Features

Goal: support users who want more than glanceable status.

Deliverables:

- Per-project usage breakdown.
- Daily, weekly, and monthly trends.
- Token and estimated-cost reports.
- Scheduled or recurring HTML reports.
- Multi-profile support if needed.
- Statusline or CLI integration if it improves workflow.
- OpenCode provider adapter.

Acceptance criteria:

- Reports are generated locally.
- Power features do not complicate the first-run experience.
- Usage and pet systems remain decoupled.

## Phase 6: Distribution

Goal: make the app installable and maintainable.

Deliverables:

- Signed macOS app if possible.
- DMG or ZIP release.
- Homebrew cask.
- Auto-update strategy.
- Crash-safe settings storage.
- First-run permission and privacy onboarding.

Acceptance criteria:

- A new user can install and understand the app in under five minutes.
- Gatekeeper and permission flows are documented.
- Release checklist exists before public launch.

## Post-v1 Options

- Windows/Linux version using Tauri.
- Custom pet skins and import format.
- Plugin/mod system.
- Voice interaction.
- Local memory or personality layer.
- More provider adapters: OpenAI API, Anthropic API, Cursor, Gemini, OpenRouter, LiteLLM.
- Team or shared reports.

## Key Risks

- Local usage formats may change.
- Credential or permission prompts can reduce trust.
- Pet interactions can become distracting if defaults are too active.
- Licensing can block direct code reuse from some references.
- Cross-platform support can slow the MVP if added too early.
