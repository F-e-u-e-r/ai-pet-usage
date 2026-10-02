# Release checklist

Run this for each release candidate. Beta-blocker criteria are at the bottom — a release with any open
blocker does not ship.

> CI gate: `swift-tests` (Swift build + `usagecore-tests`) runs on every pull request and is the required status check on `main` — a PR merges only when it is green; no human approval or owner bypass is required.

## 1. Pricing

Before each release:

1. Run `python3 Scripts/update-price-list.py`.
2. Review the regenerated `Sources/UsageCore/Resources/model-prices-generated.json`.
3. Diff generated prices against the curated `Sources/UsageCore/Resources/model-prices.json`.
4. Treat the curated file as authoritative — hand-apply only genuine provider price drift; do not blindly
   copy generated entries.
5. Confirm `model-prices.json` is valid JSON.

**Scheduled change — 2026-09-01:** Claude Sonnet 5 intro pricing ends. On/after that date, update the
`claude-sonnet-5*` entry in `model-prices.json`: input `2`→`3`, output `10`→`15`, cache-read `0.2`→`0.3`,
cache-write-5m `2.5`→`3.75`, cache-write-1h `4`→`6`, `effectiveFrom` `"2026-09-01"`, refresh the `source`
note. **Do not apply scheduled changes before their effective date.**

## 2. Build & test (must be green)

1. `Scripts/swiftpm.sh run usagecore-tests` — all tests pass.
2. `/bin/bash Scripts/test-release-version.sh` — release tooling tests pass.
3. `Scripts/build-app.sh` — produces `dist/AI Pet Usage.app`; `codesign --verify --strict` passes.

## 3. Manual smoke (see the beta gate)

Launch the app, then verify the beta gate below.

## 4. Publish

Release tags follow the canonical grammar in [`docs/release/VERSIONING.md`](release/VERSIONING.md):
`vX.Y.Z-alpha.N`, `vX.Y.Z-beta.N`, `vX.Y.Z-rc.N` or `vX.Y.Z`. Use lowercase, no leading zeros, and N ≥ 1.
The retired `alpha-v*` namespace is never used again.

1. **Annotate** the release tag on the commit to ship. That commit must already contain the canonical
   release workflow, because a tag push runs the workflow from the tagged commit.
   - Use the changelog as the tag message: bullet lines only, **no `## What's new` heading**. The release
     workflow adds that heading, and a duplicate truncates the in-app "What's new".
     e.g. `git tag -a v0.1.0-beta.1 -m "- Fixed X" -m "- Added Y"`.
   - **Tags are immutable**: the `protect-tags` ruleset forbids moving or deleting them. Check the commit
     and the tag name before pushing. A mistaken tag burns that version number, and the fix is the next
     iteration.
   - Optional rehearsal: run `release-app` via **workflow_dispatch** on the commit you intend to tag, with
     `rehearse_tag` set to the tag. It builds that commit with the tag's release identity, verifies it like
     the release, and never publishes. If the tag already exists, it must point at that commit.
2. Push the tag. The `release-app` workflow then:
   - validates the tag with `Scripts/release-version.sh`;
   - builds and ad-hoc signs the app;
   - verifies the Info.plist identity (`CFBundleShortVersionString` = `X.Y.Z`, `AIPetUsageReleaseTag` = the
     tag);
   - publishes the GitHub Release with `AI-Pet-Usage-<tag>-arm64.zip`, as a pre-release for
     `alpha` / `beta` / `rc` and as a full release for a stable `vX.Y.Z`;
   - re-verifies the published tag, pre-release flag, asset and digest;
   - for a stable release, marks the highest canonical stable release Latest and confirms it after its own
     write (`Scripts/reconcile-latest.sh`).
3. Bump the cask in `F-e-u-e-r/homebrew-tap`: run its `bump-cask` workflow, or wait about 6h. The cask
   tracks the highest canonical beta / rc / stable release.
   - Then run `brew style` and smoke `brew install --cask F-e-u-e-r/tap/ai-pet-usage`.
   - The in-app updater reads GitHub Releases directly, so a fresh release can be ahead of `brew upgrade`
     until the cask is bumped.

---

## Beta gate (must all pass to ship)

**Privacy — by destination.** The boundary is [`docs/DATA_BOUNDARY.md`](DATA_BOUNDARY.md); a violation is a
hard blocker:

- Prompt / assistant / tool content **or** auth secrets appearing **anywhere** (ledger, report, `aipet diag`,
  network) → blocker. Sole reviewed exception: the opt-in OpenRouter credits monitor may send the opencode
  key **only** as the `Authorization` header to `openrouter.ai` (DATA_BOUNDARY ‡); that key in any other
  destination — or any egress beyond the two documented opt-in calls — is still a blocker.
- A **full local path** in an **HTML report, `aipet diag`, or any network call** → blocker. (Paths in the
  local `ledger.jsonl` / `scan-state.json` are expected and are *not* a blocker.)
- **Usage token counts** are allowed in the ledger, HTML report, and diag — they are not a leak, and must
  not be confused with auth tokens/keys (which are the blocker above).
- Any outbound network call **other than** the two documented opt-in, off-by-default calls — the GitHub
  update check and the OpenRouter credits check (each sends UA `AIPetUsage/<version>`, no usage data;
  the credits call carries the opencode key **only** as its `Authorization` header, per DATA_BOUNDARY ‡)
  → blocker.
- Verify with the sentinel tests (`PrivacyHardeningTests`, `DiagnosticTests`) **and** a manual
  `aipet report --out /tmp/r.html` + `aipet diag`, then
  `grep -E "/Users/|<a prompt sentinel>" /tmp/r.html` returns nothing (bar fixed doc strings). "Looks clean"
  by eye is not sufficient for this gate.

**Correctness / usability blockers:**

- A provider parser crashes on real logs, or a limit percentage is presented as **provider-reported /
  high-confidence but is wrong** → blocker. (A value correctly labelled `estimated`, `stale`, or shown
  blank/unavailable is **not** a blocker — those are honest non-exact states.)
- Ledger data loss (events dropped / corrupted on normal use) → blocker.
- `Scripts/swiftpm.sh run usagecore-tests` red, or `build-app.sh` / `codesign --verify` fails → blocker.
- The pet is unusable in the default mode (can't be dragged, can't be interacted with) → blocker.
- The signed artifact can't be opened on a clean, **unmanaged** supported Mac via the documented
  first-launch step (xattr → Open Anyway). *Managed Macs may block Gatekeeper overrides by policy — that is
  not a beta blocker; test on an unmanaged machine.*

Anything tracked with the `beta-blocker` GitHub label must be closed (or explicitly waived by the owner with
a reason) before tagging.
