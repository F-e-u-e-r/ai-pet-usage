# Release Checklist

Use this checklist for each release candidate.

## Price List Maintenance

Before each release:

1. Run `python3 Scripts/update-price-list.py`.
2. Review the regenerated `Sources/UsageCore/Resources/model-prices-generated.json` from OpenRouter.
3. Diff generated prices against the curated `Sources/UsageCore/Resources/model-prices.json`.
4. Treat the curated file as authoritative. Hand-apply only genuine provider price drift to `model-prices.json`; do not blindly copy generated entries.
5. Verify `Sources/UsageCore/Resources/model-prices.json` is valid JSON.

### Scheduled Price Changes

- 2026-09-01 — Claude Sonnet 5 intro pricing ends. On or after this date, update the `claude-sonnet-5*` entry in `model-prices.json` from intro `$2/$10` to standard `$3/$15`:
  - `inputPerMillion`: `2` -> `3`
  - `outputPerMillion`: `10` -> `15`
  - `cacheReadPerMillion`: `0.2` -> `0.3`
  - `cacheWrite5mPerMillion`: `2.5` -> `3.75`
  - `cacheWrite1hPerMillion`: `4` -> `6`
  - `effectiveFrom`: `"2026-09-01"`
  - Refresh the `source` note with the current provider documentation.

Do not apply scheduled price changes before their effective dates.

## Verification

1. Run `Scripts/swiftpm.sh run usagecore-tests`; all tests must pass.
2. Run `Scripts/build-app.sh` to produce the `.app`.

## Release Artifact

Confirm the app bundle launches locally before publishing.
