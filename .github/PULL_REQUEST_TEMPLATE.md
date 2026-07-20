<!-- Thanks for contributing. Keep PRs focused; one concern per PR where possible. -->

## What & why
<!-- What does this change and why? Link the issue: Fixes #… -->

## Type
- [ ] Bug fix
- [ ] Feature
- [ ] Provider adapter change (see `docs/ADAPTER_CONTRACT.md`)
- [ ] Pricing data
- [ ] Docs / chore

## Checklist
- [ ] `Scripts/swiftpm.sh build` is clean and `Scripts/swiftpm.sh run usagecore-tests` passes (or CI is green).
- [ ] No prompts, assistant messages, tool payloads, or auth files are read, logged, exported, or committed.
- [ ] No token, account id, or full local path is logged, exported, committed, or surfaced in a report (a project *name* is fine; the app reads `cwd` for attribution but never surfaces the full path).
- [ ] No new outbound network call (the only allowed ones are the two existing opt-in, off-by-default checks: GitHub update check, OpenRouter credits check).
- [ ] If this touches a **provider adapter**: it follows `docs/ADAPTER_CONTRACT.md`, adds a redacted fixture + test, and keeps unavailable/estimated values honest (never faked to `0`/exact).
- [ ] If this touches **pricing**: curated `model-prices.json` only for verified prices; estimates stay labelled.
- [ ] Privacy-affecting changes are called out below.

## Privacy / security impact
<!-- "none", or describe. Reviewers will scrutinise anything that touches ledger/report/export/network. -->

## Notes for the reviewer
<!-- Anything that needs runtime/GUI verification the owner should smoke-test. -->
