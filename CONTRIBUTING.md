# Contributing

Thanks for helping. This is a local-first, no-upload AI-usage monitor with a desktop pet; the bar for
anything touching **privacy, provider parsing, or pricing** is high. Please read the relevant section
before opening a PR.

## Build & test

This is a SwiftPM project (macOS 14+). Use the wrapper script — a bare `swift build` fails on some
machines with a broken CommandLineTools toolchain:

```sh
Scripts/swiftpm.sh build
Scripts/swiftpm.sh run usagecore-tests     # custom XCTest harness; exits non-zero on failure
Scripts/build-app.sh                        # produces dist/AI Pet Usage.app (ad-hoc signed)
```

CI (`swift-tests` on macOS, `pricing-validate` on Ubuntu) runs on every PR that touches `Sources/**` or
the price lists.

## Non-negotiable privacy invariants

The product promise is: **your usage data never leaves your Mac; no telemetry; no account.** A PR must not:

- read prompts, assistant message bodies, tool payloads, or auth files;
- write any of the above into the ledger, a report, an export, or a diagnostic bundle;
- add an outbound network call other than the existing opt-in GitHub update check.

If your change is near the ledger / report / export / network layer, say so explicitly in the PR.

## Provider adapters

Adapters read local CLI logs read-only. If you add or change one, follow
[`docs/ADAPTER_CONTRACT.md`](docs/ADAPTER_CONTRACT.md): a stable **source-derived** dedup id (from log
position / provider ids, never from message content), honest confidence (`.high` only for
provider-reported values, otherwise `.estimated`; genuinely-unknown values stay absent — never a faked
`0` or exact value), and a **redacted fixture + test**. Local formats change without notice, so a fixture
is what keeps a fix from regressing.

## Pricing

Verified prices go in the curated `Sources/UsageCore/Resources/model-prices.json` (with an authoritative
source); the generated list is regenerated offline from OpenRouter's public catalog (the app never
contacts OpenRouter at runtime). Costs are always estimates; leave a model **unpriced** rather than
guessing (the UI shows `$X+` for unpriced usage — never a fake `$0`).

## Pull requests

- Keep PRs focused (one concern where possible); fill in the PR template.
- Small mechanical fixes and docs are welcome directly. For larger changes, open an issue first so we can
  agree on the approach.
- The maintainer merges; all changes are reviewed against the diff. Be ready for questions on anything
  that touches privacy, a provider parser, or pricing.

## Labels (triage)

`bug`, `enhancement`, `documentation` · `provider/claude-code`, `provider/codex`, `provider/grok-code`,
`provider/antigravity` · `area/privacy`, `area/pet`, `area/pricing` · `needs-redacted-fixture`,
`beta-blocker`.
