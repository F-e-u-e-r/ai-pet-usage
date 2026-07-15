# Security Policy

AI Pet Usage is a **local-first** macOS menu-bar app. It reads AI CLI usage logs already on your machine
and shows quota / cost / activity. It does **not** upload usage data, has no telemetry, and requires no
account or login. The only outbound network call is an **opt-in** check to the GitHub Releases API for
updates. See [`PRIVACY.md`](PRIVACY.md) for the privacy promise in plain language,
[`docs/DATA_BOUNDARY.md`](docs/DATA_BOUNDARY.md) for the per-data-class boundary checklist, and
[`docs/DATA_SOURCES.md`](docs/DATA_SOURCES.md) for exactly what is read.

## Supported versions

This is alpha software. Security fixes are made against the latest `alpha-v*` release and `main`. There is
no long-term-support branch yet.

## Reporting a vulnerability

**Please report suspected vulnerabilities or data leaks privately — do not open a public issue.**

Use GitHub's private advisory flow:
**[Report a vulnerability »](https://github.com/F-e-u-e-r/ai-pet-usage/security/advisories/new)**

When reporting, please include enough to reproduce, but **never include**:

- prompts, assistant messages, or tool payloads,
- API keys, tokens, or auth files,
- full local file paths or project contents.

Redacted evidence (provider, version, error code, the shape of a log line with values replaced) is enough
and is what a fix is built from.

## What is in scope

- An unexpected outbound network call (anything beyond the opt-in GitHub update check).
- Prompts / assistant messages / tool payloads / auth files ending up in the ledger, a report, an export,
  or a diagnostic bundle.
- Reading files outside the documented provider log locations.
- Local privilege / TCC issues in the bundled app or the `aipet` CLI.

## What is not a vulnerability

- Estimated numbers being imprecise (Grok tokens are a lower bound; Claude percentages without the
  statusline hook are estimates) — these are documented as estimates, not exact figures. File an accuracy
  issue instead.
- Gatekeeper warning on first launch (the alpha is ad-hoc signed, not yet notarized).
