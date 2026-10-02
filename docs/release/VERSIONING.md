# Release versioning (canonical namespace)

This is the normative contract for release tags, bundle versions, GitHub Releases, the in-app updater
and the Homebrew cask. Code that implements it points back here.

**Lifecycle reset (owner decision, 2026-10-02).** At the Beta boundary the project reset its public
version line. The canonical line starts at **`v0.1.0-beta.1`**. The prototype-era `alpha-vX.Y.Z` tags
are retired history ([`LEGACY-ALPHA-HISTORY.md`](LEGACY-ALPHA-HISTORY.md)):

- Legacy tags are never generated again.
- They are never predecessors in the canonical update chain.
- Legacy alpha installs are **not** promised an automatic upgrade. Migration is a manual reinstall, or a
  Homebrew upgrade/reinstall.
- Automatic-update compatibility is guaranteed only within the canonical line.

## Tag grammar

```
tag      = "v" core [ "-" pre ]
core     = num "." num "." num
pre      = channel "." iter
channel  = "alpha" / "beta" / "rc"            ; lowercase only
num      = "0" / ( nzdigit 0*8DIGIT )          ; 0 … 999,999,999, no leading zeros
iter     = nzdigit 0*8DIGIT                    ; 1 … 999,999,999, no leading zeros, never 0
DIGIT    = %x30-39 ; nzdigit = %x31-39         ; ASCII digits only
```

The four valid forms are `vX.Y.Z-alpha.N`, `vX.Y.Z-beta.N`, `vX.Y.Z-rc.N` and `vX.Y.Z`. Everything else
is rejected, including:

- the retired prefixes (`alpha-v…`, `beta-v…`, `rc-v…`);
- a missing iteration, `N = 0`, or leading zeros;
- uppercase letters, other prerelease identifiers (`-preview.1`, `-dev.1`) and build metadata (`+…`);
- whitespace, non-ASCII digits, and full ref names.

The 9-digit limit per numeric field is an implementation bound shared by every implementation so their
verdicts agree exactly; jq numbers are IEEE doubles. Versions beyond it are rejected.

Implementations, kept in agreement by the frozen 75-vector fixture
`Sources/usagecore-tests/Fixtures/canonical-version-vectors.tsv`:

| Where | Implementation | Parity check |
|---|---|---|
| App (Swift) | `Sources/UsageCore/CanonicalVersion.swift`, a byte scanner (no regex) | `CanonicalVersionTests` runs the bash script on every vector |
| Release workflow and build | `Scripts/release-version.sh` (bash, `LC_ALL=C`) | `Scripts/test-release-version.sh` |
| Homebrew tap | `scripts/select-release.jq` in `F-e-u-e-r/homebrew-tap` (anchors `\A…\z`, digits `[0-9]`) | `scripts/test-bump.sh`, using a pinned copy of the fixture |

## Ordering

```
key(v) = (major, minor, patch, rank(channel), iteration)
rank:    alpha 0 < beta 1 < rc 2 < stable 3      (stable's iteration counts as 0)
a < b  ⇔  key(a) < key(b), compared field by field as integers
```

- The core version wins over the channel: `v0.1.1-alpha.1 > v0.1.0` and `v0.2.0-alpha.1 > v0.1.9`.
- Iterations compare numerically: `alpha.2 < alpha.10`.
- A prerelease sorts below its stable release: `v0.1.0-rc.1 < v0.1.0`.
- Never use string order, publication time or API response order as version order.

## Bundle version

| Info.plist key | Value |
|---|---|
| `CFBundleShortVersionString` | `X.Y.Z`. Numeric, as Apple requires; never carries `-beta.N` |
| `CFBundleVersion` | `X.Y.Z`. A monotonic build number stays deferred to the Sparkle workstream; prerelease iterations of one core share it |
| `AIPetUsageBuildChannel` | `release`, `source` or `dev`. This is **build provenance, not the release channel** |
| `AIPetUsageReleaseTag` | The full canonical tag, e.g. `v0.1.0-beta.1`. **Release builds only**; absent for source and dev builds |

`Scripts/write-info-plist.sh` writes the plist and enforces these invariants, called by
`Scripts/build-app.sh` and checked by `release-version.sh --check-build-env`:

- `VERSION` is `X.Y.Z`.
- A release build has a canonical `RELEASE_TAG` whose `X.Y.Z` equals `VERSION`.
- Source and dev builds have no tag.

At runtime `AppVersionInfo` is the only reader:

- **Release identity.** It exists only for a well-formed release build: build channel `release`, a
  canonical tag, and the tag's core equal to `CFBundleShortVersionString`. Anything else fails closed:
  no update prompts.
- **Display version.** For a release build it is the tag without `v` (e.g. `0.1.0-beta.1`), which differs
  for every iteration. Otherwise it is the numeric core (e.g. `0.0.0` on source builds). It is used in the
  update dialogs, `aipet diag`, request User-Agents and the Grok kill marker.

## GitHub Releases

- **Triggers.** Pushing a canonical tag runs `.github/workflows/release-app.yml`.
  - The workflow's tag patterns are only a coarse filter. `Scripts/release-version.sh` is authoritative
    and fails the run before anything is built or published.
  - `workflow_dispatch` never publishes. Its optional `rehearse_tag` input builds the dispatched commit
    with that tag's release identity, verifies it like a release and uploads it as a `REHEARSAL-…`
    artifact only. Dispatch it on the commit you intend to tag: if the tag already exists, it must point
    at that commit or the rehearsal fails.
- **Flags.** `alpha` / `beta` / `rc` releases get `prerelease = true` and are not marked Latest. Stable
  releases get `prerelease = false`; Latest is the highest canonical stable. After publishing a stable
  release the workflow runs `Scripts/reconcile-latest.sh`. It marks the highest canonical stable Latest
  and then confirms after its own write: it re-lists, re-reads Latest and repeats until both agree.
  - A concurrent run's stale write is undone by that run's own confirmation, so once every run has
    finished, Latest is the highest canonical stable.
  - A run that dies between a write and its confirmation can leave Latest stale until the next stable
    publish; that run is red.
  - Stable releases are listed with a bound of 1,000, and one more is requested. A listing over the bound
    is known to be incomplete: the run fails before publishing (and reconciliation fails) rather than
    deciding Latest from a partial list.
- **Asset and title.** The asset is `AI-Pet-Usage-<tag>-arm64.zip`, with the tag verbatim including `v`.
  The title is `AI Pet Usage <tag>`. The release notes carry a channel banner: Alpha build / Beta build /
  Release candidate; a stable release carries the plain build banner.
- **Checks around publishing.**
  - Before publishing: the tag must point at the run's commit.
  - After publishing: tag, prerelease flag, the single asset's name and size, its GitHub digest against
    the local sha256, and the remote tag target are all re-verified; for a stable release, Latest too
    (`Scripts/reconcile-latest.sh`).
- **Tags are immutable.** The `protect-tags` ruleset forbids updating or deleting any tag, so a mistaken
  tag burns that version number: publish the next iteration instead.
- **Tagged commit.** A tag push runs the workflow file from the **tagged commit**. Tag a commit that
  contains this workflow.

## In-app updater

The updater lists releases with `per_page=100`. It follows `Link: rel="next"` for at most
`UpdateModel.maxReleasePages` = 10 pages, but uses the header only as a signal: page numbers are
incremented on the fixed endpoint, and a server-provided URL is never followed. If any page fails, the
whole check fails. If the 10th page still advertises a next page, the fetched list is known to be
incomplete, so the check fails too: no update decision is made from a partial list.

Across everything fetched, a release is offered only when all of these hold:

- it is not a draft;
- its tag is canonical;
- its GitHub `prerelease` flag agrees with its tag;
- it is newer than the installed version;
- it is newer than the canonical skip floor;
- it satisfies the **stability floor** below.

The **stability floor** is the installed build's channel. It applies across core versions too.

| Installed | Offered channels |
|---|---|
| alpha | alpha, beta, rc, stable |
| beta | beta, rc, stable |
| rc | rc, stable |
| stable | stable only |

For example, installed `v0.1.0` is never offered `v0.2.0-alpha.1`. When several releases qualify, the
highest is offered.

Legacy `alpha-v*` releases and a legacy `update.skippedTag` left in UserDefaults are ignored; they are
never parsed into canonical ordering.

## Homebrew cask

The main cask `ai-pet-usage` tracks the highest canonical **beta / rc / stable** release by canonical
order. Alpha releases are excluded. Whether to keep one cask or split out an `@beta` cask is revisited
after the first stable release.

- `version` is the display version (the tag without `v`).
- `url` is `…/releases/download/v#{version}/AI-Pet-Usage-v#{version}-arm64.zip`. Use only the raw
  `#{version}`: `Cask::DSL::Version#patch` splits `0.1.0-beta.1` into `0-beta`.
- The bump workflow verifies the downloaded asset against the GitHub API digest and rewrites `version`,
  `sha256` and `url` together.
- With no eligible canonical release, the cask is left unchanged. It never falls back to `alpha-v*`.
- The bump lists non-draft releases with a bound of 1,000, and one more is requested. Over the bound the
  list is known to be incomplete, so the bump fails instead of selecting from it.

Homebrew treats any cask version change as an upgrade (it compares installed and current versions for
equality). So `brew upgrade --cask ai-pet-usage` also moves a legacy `0.4.0` install to the canonical
line.
