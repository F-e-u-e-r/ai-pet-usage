# Legacy `alpha-v*` release history (retired prototype namespace)

**Status: retired.** The `alpha-vX.Y.Z` tags below are the project's prototype-alpha release history.
At the Beta boundary the project reset its public version line to the canonical SemVer prerelease
namespace (`vX.Y.Z-alpha.N`, `vX.Y.Z-beta.N`, `vX.Y.Z-rc.N`, `vX.Y.Z`), starting at `v0.1.0-beta.1`.

- Legacy `alpha-v*` versions remain part of git/project provenance, but they are **not** part of the
  canonical public prerelease version line and are never generated again.
- They are **not** predecessors in the canonical update chain: a legacy alpha install is not promised an
  automatic upgrade to the canonical line. Migration is a manual reinstall or a Homebrew reinstall/upgrade.
- Canonical release, update and Homebrew tooling must reject `alpha-vX.Y.Z` (see
  [`VERSIONING.md`](VERSIONING.md), the canonical release contract).

**Owner decision (2026-10-02): complete public namespace reset.** After the first canonical Beta
(`v0.1.0-beta.1`) is published and the Homebrew cask has migrated to it, the legacy GitHub Releases and the
remote `alpha-v*` tags are removed. The git commit history and this record are retained.

**Legacy binaries (owner-accepted retirement).** The exact legacy packaged binaries are intentionally
retired when the legacy GitHub Releases are deleted and are not retained after cleanup. Their asset names,
sizes and SHA-256 digests, and the release provenance below, are retained as durable provenance; binary
availability is not preserved.

This file preserves enough evidence that removing the public GitHub Releases and the `alpha-v*` tag refs
does not destroy release provenance: every annotated tag object is reproduced byte-for-byte (base64),
every Release body verbatim with its SHA-256, and every asset by name, size and SHA-256.

Evidence captured from the live repositories; reachability verified against `origin/main` `936d9b19223dec9b082e3a9b955ac67bc82e2a0e` at 2026-10-01T19:35:38Z.

## Summary

| Legacy tag | Tag object (annotated) | Peeled commit | Tagged (UTC) | GitHub Release id | Published (UTC) | Asset SHA-256 | Homebrew cask |
|---|---|---|---|---|---|---|---|
| `alpha-v0.1.0` | `f4f575eec28ce8f20c23327f25c3b5f938ebe234` | `56eb8bf4482461141915fae5bb2b08ed39d9fc12` | 2026-07-12T14:46:01Z | — (no Release) | — | `—` | never referenced |
| `alpha-v0.1.1` | `a461e26e5e23d916d87ff61b51bad633f262375c` | `bce876d6fc3cf0b92918b7fe02525d121cee1bca` | 2026-07-12T15:52:21Z | — (no Release) | — | `—` | never referenced |
| `alpha-v0.1.2` | `f054ebf9ea0817db9b1f101d4700fab28e7461e3` | `cc527633f73c1cc7596bd0eb97e11b5ea603eba4` | 2026-07-12T18:08:40Z | 352812407 | 2026-07-12T18:09:33Z | `a64757be9a6d207d418ab3b7d1cd69cd7887b3fcaf5f5ff7f285621ed8f0c77a` | `bc992f4`, `1892a93` |
| `alpha-v0.1.3` | `5663aa35ee32d29b3a2a5f7c36040fa6958e3c52` | `e336a8ea896de821a156b7d24c779bf70ecb0e09` | 2026-07-13T09:32:13Z | 353078660 | 2026-07-13T10:25:57Z | `9ff374bc3617e1cf7204ffe310c1f5b1ff9754d5b8e24f15c52b717221b3281d` | `e588c52` |
| `alpha-v0.1.4` | `d369419e5c9790aeefa92660d799733c619be906` | `b99de7c31f98648c7da581ece03cad99f28036e0` | 2026-07-13T17:33:36Z | 353320802 | 2026-07-13T17:34:29Z | `08937b1b6ee346ccc52fdd9bcf63d5622fa6959a357fc1f7ab2b337f5e596bcd` | never referenced |
| `alpha-v0.1.5` | `7c63a9534590d5a4a35067a49193d2491aa21ef1` | `f6c63de26c096dfc158a34160d3a3abb69eea4fc` | 2026-07-13T17:56:40Z | 353333962 | 2026-07-13T17:58:00Z | `0ddcc1036c86493cce0e212b234ecce58e8bf57c3f4c28e5cb7d6622d1ffc581` | `cc9d5ad` |
| `alpha-v0.1.6` | `ab538aea4942fbf5c8275f3371057b180e1e696b` | `ba7d55991072831b544ffdb88f776e5bd16098f6` | 2026-07-14T11:14:58Z | 353744312 | 2026-07-14T11:16:19Z | `4b01b01e7e90e0d7f2233e70e1b9d6146d19173e7f2181b60d11ba3c802aded6` | `dd182d0` |
| `alpha-v0.2.0` | `5e62c6cae90fd0b0de889441877964df52b69334` | `9db4dde9a6b86eef4a209c89365e75b419d0f276` | 2026-09-17T17:07:53Z | 390908555 | 2026-09-17T17:12:23Z | `509b13c3694ddc94fb01f8d5b6a39a3daddea105258e61b9c19c5a1947f0a6c1` | `5f4bff4` |
| `alpha-v0.3.0` | `28a2ca23a9bdda7066fa7d5ef0a33b51c01909db` | `b7c4b72ee0af40621ccd30f4efd8389927b41ab0` | 2026-09-25T18:06:52Z | 396824160 | 2026-09-25T18:08:52Z | `87e4a061588bb8b101fd84929e15d0b15c77fe5facb0f810d06395b82f636c8a` | `ec541f2` |
| `alpha-v0.4.0` | `24b8eb22ecdeee2e6f368ea09c4ed02ab8e98af0` | `56954a10d47b14e7af125f8ea7a6decab3486442` | 2026-09-27T17:03:45Z | 397735795 | 2026-09-27T17:07:34Z | `b5008d850d116b1150ac11b70562cdcda876a3dac90bfe74b920cfbffff3f9ab` | `de56a70` |

Counts: 10 annotated tags (all pushed to `origin`), 8 GitHub Releases (`alpha-v0.1.2` … `alpha-v0.4.0`),
8 assets, 7 versions ever published in the Homebrew cask. `alpha-v0.1.0` and `alpha-v0.1.1` have no
Release because they predate the release workflow (the first packaged release was `alpha-v0.1.2`).
`alpha-v0.1.4` was released but never reached the cask: `alpha-v0.1.5` was published 24 minutes later
and the 6-hourly bump selected it.

## Reconstruction and verification

- **Tag object:** decode the base64 block and hash it as a tag object; the result must equal the recorded
  tag object SHA. Example: `base64 -d < obj.b64 > obj && git hash-object -t tag obj`. Restoring a deleted
  ref would be `git hash-object -w -t tag obj` followed by `git update-ref refs/tags/<tag> <sha>` and a
  push — a release-namespace mutation that needs explicit owner authorization.
- **Release body:** the base64 block decodes to the exact body bytes; their SHA-256 must equal the
  recorded `body sha256`. The readable copy is the same text inside a fenced block (the fence drops the
  final newline; the base64 is authoritative).
- **Asset:** the recorded SHA-256 equals both GitHub's asset `digest` and an independent download hash
  taken when this file was prepared.
- **Release timestamps:** GitHub's `created_at` is the date of the tag/commit the Release points to, not
  the publication time; `published_at` is when the Release went public.

## Per-tag records

### `alpha-v0.1.0`

- Tag type: annotated (tag object `f4f575eec28ce8f20c23327f25c3b5f938ebe234`)
- Peeled commit: `56eb8bf4482461141915fae5bb2b08ed39d9fc12` — "Pet panel R2: per-provider rings around the pet, layout-stable bubble, drag pause (#10)"
- Commit reachable from `main` without the tag ref: yes (ancestor of `origin/main` `936d9b1`)
- Tagger: F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com>, 2026-07-12T14:46:01Z (raw `1783867561 +0800`)
- GitHub Release: none (orphan tag; predates the release workflow)
- Homebrew: never referenced by the cask

Annotated tag object (verbatim):

```text
object 56eb8bf4482461141915fae5bb2b08ed39d9fc12
type commit
tag alpha-v0.1.0
tagger F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com> 1783867561 +0800

alpha-v0.1.0 — local-first AI usage monitor with pixel pet

Three providers (Claude Code / Codex / Grok CLI) with official-limit
arbitration (window-flap + same-window decrease confirmation), plan tier
labels, per-provider usage rings around the pet, movement controls, cursor
tooltips across all charts, and the Engine V2 demo channel with the blue
bird (E2a). Suite: 26,194 assertions; CI green.

Every change reviewed to zero findings by grok-4.5 (max) and GPT-5.5 (xhigh).
```

Annotated tag object (base64, 638 bytes, git tag object `f4f575eec28ce8f20c23327f25c3b5f938ebe234`):

```text
b2JqZWN0IDU2ZWI4YmY0NDgyNDYxMTQxOTE1ZmFlNWJiMmIwOGVkMzlkOWZjMTIKdHlwZSBjb21t
aXQKdGFnIGFscGhhLXYwLjEuMAp0YWdnZXIgRi1lLXUtZS1yIDwxODk0NjQzMDMrRi1lLXUtZS1y
QHVzZXJzLm5vcmVwbHkuZ2l0aHViLmNvbT4gMTc4Mzg2NzU2MSArMDgwMAoKYWxwaGEtdjAuMS4w
IOKAlCBsb2NhbC1maXJzdCBBSSB1c2FnZSBtb25pdG9yIHdpdGggcGl4ZWwgcGV0CgpUaHJlZSBw
cm92aWRlcnMgKENsYXVkZSBDb2RlIC8gQ29kZXggLyBHcm9rIENMSSkgd2l0aCBvZmZpY2lhbC1s
aW1pdAphcmJpdHJhdGlvbiAod2luZG93LWZsYXAgKyBzYW1lLXdpbmRvdyBkZWNyZWFzZSBjb25m
aXJtYXRpb24pLCBwbGFuIHRpZXIKbGFiZWxzLCBwZXItcHJvdmlkZXIgdXNhZ2UgcmluZ3MgYXJv
dW5kIHRoZSBwZXQsIG1vdmVtZW50IGNvbnRyb2xzLCBjdXJzb3IKdG9vbHRpcHMgYWNyb3NzIGFs
bCBjaGFydHMsIGFuZCB0aGUgRW5naW5lIFYyIGRlbW8gY2hhbm5lbCB3aXRoIHRoZSBibHVlCmJp
cmQgKEUyYSkuIFN1aXRlOiAyNiwxOTQgYXNzZXJ0aW9uczsgQ0kgZ3JlZW4uCgpFdmVyeSBjaGFu
Z2UgcmV2aWV3ZWQgdG8gemVybyBmaW5kaW5ncyBieSBncm9rLTQuNSAobWF4KSBhbmQgR1BULTUu
NSAoeGhpZ2gpLgo=
```

### `alpha-v0.1.1`

- Tag type: annotated (tag object `a461e26e5e23d916d87ff61b51bad633f262375c`)
- Peeled commit: `bce876d6fc3cf0b92918b7fe02525d121cee1bca` — "Pet panel R3: bubble above the rings, natural facing, jump ears, heatmap card, thousands separators (#11)"
- Commit reachable from `main` without the tag ref: yes (ancestor of `origin/main` `936d9b1`)
- Tagger: F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com>, 2026-07-12T15:52:21Z (raw `1783871541 +0800`)
- GitHub Release: none (orphan tag; predates the release workflow)
- Homebrew: never referenced by the cask

Annotated tag object (verbatim):

```text
object bce876d6fc3cf0b92918b7fe02525d121cee1bca
type commit
tag alpha-v0.1.1
tagger F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com> 1783871541 +0800

alpha-v0.1.1 — pet panel polish round

Bubble above the usage rings, natural facing on click, dog jump ears
restored, heatmap detail card, thousands separators app-wide, yyyy-MM-dd
date pickers, 10% movement floor, and an Install (alpha) guide.
Suite: 26,209 assertions; reviewed to CLEAN by grok-4.5 (max) and
GPT-5.5 (xhigh).
```

Annotated tag object (base64, 489 bytes, git tag object `a461e26e5e23d916d87ff61b51bad633f262375c`):

```text
b2JqZWN0IGJjZTg3NmQ2ZmMzY2YwYjkyOTE4YjdmZTAyNTI1ZDEyMWNlZTFiY2EKdHlwZSBjb21t
aXQKdGFnIGFscGhhLXYwLjEuMQp0YWdnZXIgRi1lLXUtZS1yIDwxODk0NjQzMDMrRi1lLXUtZS1y
QHVzZXJzLm5vcmVwbHkuZ2l0aHViLmNvbT4gMTc4Mzg3MTU0MSArMDgwMAoKYWxwaGEtdjAuMS4x
IOKAlCBwZXQgcGFuZWwgcG9saXNoIHJvdW5kCgpCdWJibGUgYWJvdmUgdGhlIHVzYWdlIHJpbmdz
LCBuYXR1cmFsIGZhY2luZyBvbiBjbGljaywgZG9nIGp1bXAgZWFycwpyZXN0b3JlZCwgaGVhdG1h
cCBkZXRhaWwgY2FyZCwgdGhvdXNhbmRzIHNlcGFyYXRvcnMgYXBwLXdpZGUsIHl5eXktTU0tZGQK
ZGF0ZSBwaWNrZXJzLCAxMCUgbW92ZW1lbnQgZmxvb3IsIGFuZCBhbiBJbnN0YWxsIChhbHBoYSkg
Z3VpZGUuClN1aXRlOiAyNiwyMDkgYXNzZXJ0aW9uczsgcmV2aWV3ZWQgdG8gQ0xFQU4gYnkgZ3Jv
ay00LjUgKG1heCkgYW5kCkdQVC01LjUgKHhoaWdoKS4K
```

### `alpha-v0.1.2`

- Tag type: annotated (tag object `f054ebf9ea0817db9b1f101d4700fab28e7461e3`)
- Peeled commit: `cc527633f73c1cc7596bd0eb97e11b5ea603eba4` — "release-app: fix YAML parse failure (flush-left heredoc broke the run block) (#13)"
- Commit reachable from `main` without the tag ref: yes (ancestor of `origin/main` `936d9b1`)
- Tagger: F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com>, 2026-07-12T18:08:40Z (raw `1783879720 +0800`)
- GitHub Release: id 352812407, title "AI Pet Usage alpha-v0.1.2", draft false, prerelease true, target_commitish `main`, author `github-actions[bot]`
- Release created_at 2026-07-12T18:08:40Z · published_at 2026-07-12T18:09:33Z
- Asset: `AI-Pet-Usage-alpha-v0.1.2-arm64.zip` · 1764362 bytes · sha256 `a64757be9a6d207d418ab3b7d1cd69cd7887b3fcaf5f5ff7f285621ed8f0c77a` · uploader `github-actions[bot]`
- Asset URL (historical): `https://github.com/F-e-u-e-r/ai-pet-usage/releases/download/alpha-v0.1.2/AI-Pet-Usage-alpha-v0.1.2-arm64.zip`
- Homebrew: `F-e-u-e-r/homebrew-tap` commit `bc992f4501304785996b44dfb32ece112c268157` (2026-07-13T14:19:15+08:00) set cask version `0.1.2`, sha256 `a64757be9a6d207d418ab3b7d1cd69cd7887b3fcaf5f5ff7f285621ed8f0c77a` (matches the Release asset); url template `.../releases/download/alpha-v#{version}/AI-Pet-Usage-alpha-v#{version}-arm64.zip`
- Homebrew: `F-e-u-e-r/homebrew-tap` commit `1892a93659f02d66a1793b46606e7df9c3567264` (2026-07-13T15:48:12+08:00) set cask version `0.1.2`, sha256 `a64757be9a6d207d418ab3b7d1cd69cd7887b3fcaf5f5ff7f285621ed8f0c77a` (matches the Release asset); url template `.../releases/download/alpha-v#{version}/AI-Pet-Usage-alpha-v#{version}-arm64.zip`

Annotated tag object (verbatim):

```text
object cc527633f73c1cc7596bd0eb97e11b5ea603eba4
type commit
tag alpha-v0.1.2
tagger F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com> 1783879720 +0800

alpha-v0.1.2 — pet polish + first packaged release

Bubble hugs the actual outer ring, movement-range drift fixed (band now
fixed at the placement point), cursor tooltips right of the pointer with
intrinsic width everywhere, one number-formatting primitive with rounding-
overflow promotion, and the first GitHub Actions packaged build (ad-hoc
arm64 zip attached to this release). Suite: 26,224 assertions; reviewed to
CLEAN by grok-4.5 (max) and GPT-5.5 (xhigh).
```

Annotated tag object (base64, 625 bytes, git tag object `f054ebf9ea0817db9b1f101d4700fab28e7461e3`):

```text
b2JqZWN0IGNjNTI3NjMzZjczYzFjYzc1OTZiZDBlYjk3ZTExYjVlYTYwM2ViYTQKdHlwZSBjb21t
aXQKdGFnIGFscGhhLXYwLjEuMgp0YWdnZXIgRi1lLXUtZS1yIDwxODk0NjQzMDMrRi1lLXUtZS1y
QHVzZXJzLm5vcmVwbHkuZ2l0aHViLmNvbT4gMTc4Mzg3OTcyMCArMDgwMAoKYWxwaGEtdjAuMS4y
IOKAlCBwZXQgcG9saXNoICsgZmlyc3QgcGFja2FnZWQgcmVsZWFzZQoKQnViYmxlIGh1Z3MgdGhl
IGFjdHVhbCBvdXRlciByaW5nLCBtb3ZlbWVudC1yYW5nZSBkcmlmdCBmaXhlZCAoYmFuZCBub3cK
Zml4ZWQgYXQgdGhlIHBsYWNlbWVudCBwb2ludCksIGN1cnNvciB0b29sdGlwcyByaWdodCBvZiB0
aGUgcG9pbnRlciB3aXRoCmludHJpbnNpYyB3aWR0aCBldmVyeXdoZXJlLCBvbmUgbnVtYmVyLWZv
cm1hdHRpbmcgcHJpbWl0aXZlIHdpdGggcm91bmRpbmctCm92ZXJmbG93IHByb21vdGlvbiwgYW5k
IHRoZSBmaXJzdCBHaXRIdWIgQWN0aW9ucyBwYWNrYWdlZCBidWlsZCAoYWQtaG9jCmFybTY0IHpp
cCBhdHRhY2hlZCB0byB0aGlzIHJlbGVhc2UpLiBTdWl0ZTogMjYsMjI0IGFzc2VydGlvbnM7IHJl
dmlld2VkIHRvCkNMRUFOIGJ5IGdyb2stNC41IChtYXgpIGFuZCBHUFQtNS41ICh4aGlnaCkuCg==
```

Release body (verbatim; 481 bytes, sha256 `3a463f7e3e8dffa632efb7d50a03482b5822ed9f1b94a6899e33d2ffa8f0b0b7`):

```text
**Alpha build — Apple Silicon (arm64), ad-hoc signed, not notarized.**

macOS will quarantine this download. To open the first time, either:
- right-click **AI Pet Usage.app** → **Open** → **Open**, or
- run `xattr -d com.apple.quarantine "AI Pet Usage.app"` after unzipping.

Requirements: macOS 14+. Intel Macs: build from source (see README → Install).
Everything is local-first — the app reads Claude Code / Codex / Grok CLI logs on your machine and uploads nothing.
```

Release body (base64):

```text
KipBbHBoYSBidWlsZCDigJQgQXBwbGUgU2lsaWNvbiAoYXJtNjQpLCBhZC1ob2Mgc2lnbmVkLCBu
b3Qgbm90YXJpemVkLioqCgptYWNPUyB3aWxsIHF1YXJhbnRpbmUgdGhpcyBkb3dubG9hZC4gVG8g
b3BlbiB0aGUgZmlyc3QgdGltZSwgZWl0aGVyOgotIHJpZ2h0LWNsaWNrICoqQUkgUGV0IFVzYWdl
LmFwcCoqIOKGkiAqKk9wZW4qKiDihpIgKipPcGVuKiosIG9yCi0gcnVuIGB4YXR0ciAtZCBjb20u
YXBwbGUucXVhcmFudGluZSAiQUkgUGV0IFVzYWdlLmFwcCJgIGFmdGVyIHVuemlwcGluZy4KClJl
cXVpcmVtZW50czogbWFjT1MgMTQrLiBJbnRlbCBNYWNzOiBidWlsZCBmcm9tIHNvdXJjZSAoc2Vl
IFJFQURNRSDihpIgSW5zdGFsbCkuCkV2ZXJ5dGhpbmcgaXMgbG9jYWwtZmlyc3Qg4oCUIHRoZSBh
cHAgcmVhZHMgQ2xhdWRlIENvZGUgLyBDb2RleCAvIEdyb2sgQ0xJIGxvZ3Mgb24geW91ciBtYWNo
aW5lIGFuZCB1cGxvYWRzIG5vdGhpbmcuCg==
```

### `alpha-v0.1.3`

- Tag type: annotated (tag object `5663aa35ee32d29b3a2a5f7c36040fa6958e3c52`)
- Peeled commit: `e336a8ea896de821a156b7d24c779bf70ecb0e09` — "Homebrew install + opt-in in-app update notifier (A2) (#15)"
- Commit reachable from `main` without the tag ref: yes (ancestor of `origin/main` `936d9b1`)
- Tagger: F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com>, 2026-07-13T09:32:13Z (raw `1783935133 +0800`)
- GitHub Release: id 353078660, title "AI Pet Usage alpha-v0.1.3", draft false, prerelease true, target_commitish `main`, author `github-actions[bot]`
- Release created_at 2026-07-13T09:32:13Z · published_at 2026-07-13T10:25:57Z
- Asset: `AI-Pet-Usage-alpha-v0.1.3-arm64.zip` · 1805146 bytes · sha256 `9ff374bc3617e1cf7204ffe310c1f5b1ff9754d5b8e24f15c52b717221b3281d` · uploader `github-actions[bot]`
- Asset URL (historical): `https://github.com/F-e-u-e-r/ai-pet-usage/releases/download/alpha-v0.1.3/AI-Pet-Usage-alpha-v0.1.3-arm64.zip`
- Homebrew: `F-e-u-e-r/homebrew-tap` commit `e588c52550d4ecf312853d01d160a41d2393f22f` (2026-07-13T15:09:37Z) set cask version `0.1.3`, sha256 `9ff374bc3617e1cf7204ffe310c1f5b1ff9754d5b8e24f15c52b717221b3281d` (matches the Release asset); url template `.../releases/download/alpha-v#{version}/AI-Pet-Usage-alpha-v#{version}-arm64.zip`

Annotated tag object (verbatim):

```text
object e336a8ea896de821a156b7d24c779bf70ecb0e09
type commit
tag alpha-v0.1.3
tagger F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com> 1783935133 +0800

alpha-v0.1.3 — Homebrew install + in-app update notifier

Install via Homebrew cask (brew install --cask F-e-u-e-r/tap/ai-pet-usage)
plus an opt-in in-app update notifier that surfaces newer alpha releases
(release channel only; source/dev builds stay silent). Also folds in the
R5 pass: pet eat/jump head-crop fix, Codex 5-hour usage-window
classification with durable freeze across restarts, and a Traditional
Chinese (zh-Hant) README.

Alpha build — Apple Silicon (arm64), ad-hoc signed, not notarized.
```

Annotated tag object (base64, 669 bytes, git tag object `5663aa35ee32d29b3a2a5f7c36040fa6958e3c52`):

```text
b2JqZWN0IGUzMzZhOGVhODk2ZGU4MjFhMTU2YjdkMjRjNzc5YmY3MGVjYjBlMDkKdHlwZSBjb21t
aXQKdGFnIGFscGhhLXYwLjEuMwp0YWdnZXIgRi1lLXUtZS1yIDwxODk0NjQzMDMrRi1lLXUtZS1y
QHVzZXJzLm5vcmVwbHkuZ2l0aHViLmNvbT4gMTc4MzkzNTEzMyArMDgwMAoKYWxwaGEtdjAuMS4z
IOKAlCBIb21lYnJldyBpbnN0YWxsICsgaW4tYXBwIHVwZGF0ZSBub3RpZmllcgoKSW5zdGFsbCB2
aWEgSG9tZWJyZXcgY2FzayAoYnJldyBpbnN0YWxsIC0tY2FzayBGLWUtdS1lLXIvdGFwL2FpLXBl
dC11c2FnZSkKcGx1cyBhbiBvcHQtaW4gaW4tYXBwIHVwZGF0ZSBub3RpZmllciB0aGF0IHN1cmZh
Y2VzIG5ld2VyIGFscGhhIHJlbGVhc2VzCihyZWxlYXNlIGNoYW5uZWwgb25seTsgc291cmNlL2Rl
diBidWlsZHMgc3RheSBzaWxlbnQpLiBBbHNvIGZvbGRzIGluIHRoZQpSNSBwYXNzOiBwZXQgZWF0
L2p1bXAgaGVhZC1jcm9wIGZpeCwgQ29kZXggNS1ob3VyIHVzYWdlLXdpbmRvdwpjbGFzc2lmaWNh
dGlvbiB3aXRoIGR1cmFibGUgZnJlZXplIGFjcm9zcyByZXN0YXJ0cywgYW5kIGEgVHJhZGl0aW9u
YWwKQ2hpbmVzZSAoemgtSGFudCkgUkVBRE1FLgoKQWxwaGEgYnVpbGQg4oCUIEFwcGxlIFNpbGlj
b24gKGFybTY0KSwgYWQtaG9jIHNpZ25lZCwgbm90IG5vdGFyaXplZC4K
```

Release body (verbatim; 1063 bytes, sha256 `4f9af04a3071f622b6371b25a39348fee0daf6e2130d27ecf1ddce58f8a09210`):

```text
## What's new

Install via Homebrew cask (`brew install --cask F-e-u-e-r/tap/ai-pet-usage`) plus an opt-in in-app update notifier that surfaces newer alpha releases (release channel only; source/dev builds stay silent). Also folds in the R5 pass: pet eat/jump head-crop fix, Codex 5-hour usage-window classification with durable freeze across restarts, and a Traditional Chinese (zh-Hant) README.

## Install

Homebrew (Apple Silicon, recommended):

    brew install --cask F-e-u-e-r/tap/ai-pet-usage

Or download the arm64 zip below and drag the app to Applications.

**Alpha build — Apple Silicon (arm64), ad-hoc signed, not notarized.**
macOS blocks the first launch: open the app, then System Settings → Privacy & Security → **Open Anyway** (only if you trust this release).
Homebrew does not remove this one-time approval; only Developer ID notarization would.

Requirements: macOS 14+. Intel Macs: build from source (see README → Install).
Local-first: the app reads Claude Code / Codex / Grok CLI logs on your machine; it never uploads usage data.
```

Release body (base64):

```text
IyMgV2hhdCdzIG5ldwoKSW5zdGFsbCB2aWEgSG9tZWJyZXcgY2FzayAoYGJyZXcgaW5zdGFsbCAt
LWNhc2sgRi1lLXUtZS1yL3RhcC9haS1wZXQtdXNhZ2VgKSBwbHVzIGFuIG9wdC1pbiBpbi1hcHAg
dXBkYXRlIG5vdGlmaWVyIHRoYXQgc3VyZmFjZXMgbmV3ZXIgYWxwaGEgcmVsZWFzZXMgKHJlbGVh
c2UgY2hhbm5lbCBvbmx5OyBzb3VyY2UvZGV2IGJ1aWxkcyBzdGF5IHNpbGVudCkuIEFsc28gZm9s
ZHMgaW4gdGhlIFI1IHBhc3M6IHBldCBlYXQvanVtcCBoZWFkLWNyb3AgZml4LCBDb2RleCA1LWhv
dXIgdXNhZ2Utd2luZG93IGNsYXNzaWZpY2F0aW9uIHdpdGggZHVyYWJsZSBmcmVlemUgYWNyb3Nz
IHJlc3RhcnRzLCBhbmQgYSBUcmFkaXRpb25hbCBDaGluZXNlICh6aC1IYW50KSBSRUFETUUuCgoj
IyBJbnN0YWxsCgpIb21lYnJldyAoQXBwbGUgU2lsaWNvbiwgcmVjb21tZW5kZWQpOgoKICAgIGJy
ZXcgaW5zdGFsbCAtLWNhc2sgRi1lLXUtZS1yL3RhcC9haS1wZXQtdXNhZ2UKCk9yIGRvd25sb2Fk
IHRoZSBhcm02NCB6aXAgYmVsb3cgYW5kIGRyYWcgdGhlIGFwcCB0byBBcHBsaWNhdGlvbnMuCgoq
KkFscGhhIGJ1aWxkIOKAlCBBcHBsZSBTaWxpY29uIChhcm02NCksIGFkLWhvYyBzaWduZWQsIG5v
dCBub3Rhcml6ZWQuKioKbWFjT1MgYmxvY2tzIHRoZSBmaXJzdCBsYXVuY2g6IG9wZW4gdGhlIGFw
cCwgdGhlbiBTeXN0ZW0gU2V0dGluZ3Mg4oaSIFByaXZhY3kgJiBTZWN1cml0eSDihpIgKipPcGVu
IEFueXdheSoqIChvbmx5IGlmIHlvdSB0cnVzdCB0aGlzIHJlbGVhc2UpLgpIb21lYnJldyBkb2Vz
IG5vdCByZW1vdmUgdGhpcyBvbmUtdGltZSBhcHByb3ZhbDsgb25seSBEZXZlbG9wZXIgSUQgbm90
YXJpemF0aW9uIHdvdWxkLgoKUmVxdWlyZW1lbnRzOiBtYWNPUyAxNCsuIEludGVsIE1hY3M6IGJ1
aWxkIGZyb20gc291cmNlIChzZWUgUkVBRE1FIOKGkiBJbnN0YWxsKS4KTG9jYWwtZmlyc3Q6IHRo
ZSBhcHAgcmVhZHMgQ2xhdWRlIENvZGUgLyBDb2RleCAvIEdyb2sgQ0xJIGxvZ3Mgb24geW91ciBt
YWNoaW5lOyBpdCBuZXZlciB1cGxvYWRzIHVzYWdlIGRhdGEuCg==
```

### `alpha-v0.1.4`

- Tag type: annotated (tag object `d369419e5c9790aeefa92660d799733c619be906`)
- Peeled commit: `b99de7c31f98648c7da581ece03cad99f28036e0` — "Claude idle 5h window + adaptive timeline axis + daily price refresh + release-notes fix (#16)"
- Commit reachable from `main` without the tag ref: yes (ancestor of `origin/main` `936d9b1`)
- Tagger: F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com>, 2026-07-13T17:33:36Z (raw `1783964016 +0800`)
- GitHub Release: id 353320802, title "AI Pet Usage alpha-v0.1.4", draft false, prerelease true, target_commitish `main`, author `github-actions[bot]`
- Release created_at 2026-07-13T17:33:36Z · published_at 2026-07-13T17:34:29Z
- Asset: `AI-Pet-Usage-alpha-v0.1.4-arm64.zip` · 1812210 bytes · sha256 `08937b1b6ee346ccc52fdd9bcf63d5622fa6959a357fc1f7ab2b337f5e596bcd` · uploader `github-actions[bot]`
- Asset URL (historical): `https://github.com/F-e-u-e-r/ai-pet-usage/releases/download/alpha-v0.1.4/AI-Pet-Usage-alpha-v0.1.4-arm64.zip`
- Homebrew: never referenced by the cask

Annotated tag object (verbatim):

```text
object b99de7c31f98648c7da581ece03cad99f28036e0
type commit
tag alpha-v0.1.4
tagger F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com> 1783964016 +0800

alpha-v0.1.4 — Claude idle 5h window + adaptive timeline axis + auto price refresh

Claude's 5-hour limit no longer vanishes from the menu bar when you haven't
used Claude for a while: an idle window now reads "idle · no active 5h window"
(never a fake 0%), consistent with how Codex's windows persist, and distinct
from a genuine no-data state ("unknown · no local Claude usage found"). The
Today timeline's x-axis labels adapt to the number of bars — few bars label
every hour, a full day uses clock-friendly ticks with the current hour always
labelled. The model price list now refreshes daily via a GitHub Actions
workflow (the retired cloud routine couldn't reach OpenRouter), and release
notes now render from the annotated tag message.

Alpha build — Apple Silicon (arm64), ad-hoc signed, not notarized.
```

Annotated tag object (base64, 978 bytes, git tag object `d369419e5c9790aeefa92660d799733c619be906`):

```text
b2JqZWN0IGI5OWRlN2MzMWY5ODY0OGM3ZGE1ODFlY2UwM2NhZDk5ZjI4MDM2ZTAKdHlwZSBjb21t
aXQKdGFnIGFscGhhLXYwLjEuNAp0YWdnZXIgRi1lLXUtZS1yIDwxODk0NjQzMDMrRi1lLXUtZS1y
QHVzZXJzLm5vcmVwbHkuZ2l0aHViLmNvbT4gMTc4Mzk2NDAxNiArMDgwMAoKYWxwaGEtdjAuMS40
IOKAlCBDbGF1ZGUgaWRsZSA1aCB3aW5kb3cgKyBhZGFwdGl2ZSB0aW1lbGluZSBheGlzICsgYXV0
byBwcmljZSByZWZyZXNoCgpDbGF1ZGUncyA1LWhvdXIgbGltaXQgbm8gbG9uZ2VyIHZhbmlzaGVz
IGZyb20gdGhlIG1lbnUgYmFyIHdoZW4geW91IGhhdmVuJ3QKdXNlZCBDbGF1ZGUgZm9yIGEgd2hp
bGU6IGFuIGlkbGUgd2luZG93IG5vdyByZWFkcyAiaWRsZSDCtyBubyBhY3RpdmUgNWggd2luZG93
IgoobmV2ZXIgYSBmYWtlIDAlKSwgY29uc2lzdGVudCB3aXRoIGhvdyBDb2RleCdzIHdpbmRvd3Mg
cGVyc2lzdCwgYW5kIGRpc3RpbmN0CmZyb20gYSBnZW51aW5lIG5vLWRhdGEgc3RhdGUgKCJ1bmtu
b3duIMK3IG5vIGxvY2FsIENsYXVkZSB1c2FnZSBmb3VuZCIpLiBUaGUKVG9kYXkgdGltZWxpbmUn
cyB4LWF4aXMgbGFiZWxzIGFkYXB0IHRvIHRoZSBudW1iZXIgb2YgYmFycyDigJQgZmV3IGJhcnMg
bGFiZWwKZXZlcnkgaG91ciwgYSBmdWxsIGRheSB1c2VzIGNsb2NrLWZyaWVuZGx5IHRpY2tzIHdp
dGggdGhlIGN1cnJlbnQgaG91ciBhbHdheXMKbGFiZWxsZWQuIFRoZSBtb2RlbCBwcmljZSBsaXN0
IG5vdyByZWZyZXNoZXMgZGFpbHkgdmlhIGEgR2l0SHViIEFjdGlvbnMKd29ya2Zsb3cgKHRoZSBy
ZXRpcmVkIGNsb3VkIHJvdXRpbmUgY291bGRuJ3QgcmVhY2ggT3BlblJvdXRlciksIGFuZCByZWxl
YXNlCm5vdGVzIG5vdyByZW5kZXIgZnJvbSB0aGUgYW5ub3RhdGVkIHRhZyBtZXNzYWdlLgoKQWxw
aGEgYnVpbGQg4oCUIEFwcGxlIFNpbGljb24gKGFybTY0KSwgYWQtaG9jIHNpZ25lZCwgbm90IG5v
dGFyaXplZC4K
```

Release body (verbatim; 1344 bytes, sha256 `621c743aa5df89f9d13ff78e6f663a5e8958374d3336ff8615cbfc51e792d193`):

```text
## What's new

Claude's 5-hour limit no longer vanishes from the menu bar when you haven't used Claude for a while: an idle window now reads "idle · no active 5h window" (never a fake 0%), consistent with how Codex's windows persist, and distinct from a genuine no-data state ("unknown · no local Claude usage found"). The Today timeline's x-axis labels adapt to the number of bars — few bars label every hour, a full day uses clock-friendly ticks with the current hour always labelled. The model price list now refreshes daily via a GitHub Actions workflow (the retired cloud routine couldn't reach OpenRouter), and release notes now render from the annotated tag message.

## Install

Homebrew (Apple Silicon, recommended):

    brew install --cask F-e-u-e-r/tap/ai-pet-usage

Or download the arm64 zip below and drag the app to Applications.

**Alpha build — Apple Silicon (arm64), ad-hoc signed, not notarized.**
macOS blocks the first launch: open the app, then System Settings → Privacy & Security → **Open Anyway** (only if you trust this release).
Homebrew does not remove this one-time approval; only Developer ID notarization would.

Requirements: macOS 14+. Intel Macs: build from source (see README → Install).
Local-first: the app reads Claude Code / Codex / Grok CLI logs on your machine; it never uploads usage data.
```

Release body (base64):

```text
IyMgV2hhdCdzIG5ldwoKQ2xhdWRlJ3MgNS1ob3VyIGxpbWl0IG5vIGxvbmdlciB2YW5pc2hlcyBm
cm9tIHRoZSBtZW51IGJhciB3aGVuIHlvdSBoYXZlbid0IHVzZWQgQ2xhdWRlIGZvciBhIHdoaWxl
OiBhbiBpZGxlIHdpbmRvdyBub3cgcmVhZHMgImlkbGUgwrcgbm8gYWN0aXZlIDVoIHdpbmRvdyIg
KG5ldmVyIGEgZmFrZSAwJSksIGNvbnNpc3RlbnQgd2l0aCBob3cgQ29kZXgncyB3aW5kb3dzIHBl
cnNpc3QsIGFuZCBkaXN0aW5jdCBmcm9tIGEgZ2VudWluZSBuby1kYXRhIHN0YXRlICgidW5rbm93
biDCtyBubyBsb2NhbCBDbGF1ZGUgdXNhZ2UgZm91bmQiKS4gVGhlIFRvZGF5IHRpbWVsaW5lJ3Mg
eC1heGlzIGxhYmVscyBhZGFwdCB0byB0aGUgbnVtYmVyIG9mIGJhcnMg4oCUIGZldyBiYXJzIGxh
YmVsIGV2ZXJ5IGhvdXIsIGEgZnVsbCBkYXkgdXNlcyBjbG9jay1mcmllbmRseSB0aWNrcyB3aXRo
IHRoZSBjdXJyZW50IGhvdXIgYWx3YXlzIGxhYmVsbGVkLiBUaGUgbW9kZWwgcHJpY2UgbGlzdCBu
b3cgcmVmcmVzaGVzIGRhaWx5IHZpYSBhIEdpdEh1YiBBY3Rpb25zIHdvcmtmbG93ICh0aGUgcmV0
aXJlZCBjbG91ZCByb3V0aW5lIGNvdWxkbid0IHJlYWNoIE9wZW5Sb3V0ZXIpLCBhbmQgcmVsZWFz
ZSBub3RlcyBub3cgcmVuZGVyIGZyb20gdGhlIGFubm90YXRlZCB0YWcgbWVzc2FnZS4KCiMjIElu
c3RhbGwKCkhvbWVicmV3IChBcHBsZSBTaWxpY29uLCByZWNvbW1lbmRlZCk6CgogICAgYnJldyBp
bnN0YWxsIC0tY2FzayBGLWUtdS1lLXIvdGFwL2FpLXBldC11c2FnZQoKT3IgZG93bmxvYWQgdGhl
IGFybTY0IHppcCBiZWxvdyBhbmQgZHJhZyB0aGUgYXBwIHRvIEFwcGxpY2F0aW9ucy4KCioqQWxw
aGEgYnVpbGQg4oCUIEFwcGxlIFNpbGljb24gKGFybTY0KSwgYWQtaG9jIHNpZ25lZCwgbm90IG5v
dGFyaXplZC4qKgptYWNPUyBibG9ja3MgdGhlIGZpcnN0IGxhdW5jaDogb3BlbiB0aGUgYXBwLCB0
aGVuIFN5c3RlbSBTZXR0aW5ncyDihpIgUHJpdmFjeSAmIFNlY3VyaXR5IOKGkiAqKk9wZW4gQW55
d2F5KiogKG9ubHkgaWYgeW91IHRydXN0IHRoaXMgcmVsZWFzZSkuCkhvbWVicmV3IGRvZXMgbm90
IHJlbW92ZSB0aGlzIG9uZS10aW1lIGFwcHJvdmFsOyBvbmx5IERldmVsb3BlciBJRCBub3Rhcml6
YXRpb24gd291bGQuCgpSZXF1aXJlbWVudHM6IG1hY09TIDE0Ky4gSW50ZWwgTWFjczogYnVpbGQg
ZnJvbSBzb3VyY2UgKHNlZSBSRUFETUUg4oaSIEluc3RhbGwpLgpMb2NhbC1maXJzdDogdGhlIGFw
cCByZWFkcyBDbGF1ZGUgQ29kZSAvIENvZGV4IC8gR3JvayBDTEkgbG9ncyBvbiB5b3VyIG1hY2hp
bmU7IGl0IG5ldmVyIHVwbG9hZHMgdXNhZ2UgZGF0YS4K
```

### `alpha-v0.1.5`

- Tag type: annotated (tag object `7c63a9534590d5a4a35067a49193d2491aa21ef1`)
- Peeled commit: `f6c63de26c096dfc158a34160d3a3abb69eea4fc` — "release-app: re-fetch annotated tag so release notes render (fetch-depth was insufficient) (#17)"
- Commit reachable from `main` without the tag ref: yes (ancestor of `origin/main` `936d9b1`)
- Tagger: F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com>, 2026-07-13T17:56:40Z (raw `1783965400 +0800`)
- GitHub Release: id 353333962, title "AI Pet Usage alpha-v0.1.5", draft false, prerelease true, target_commitish `main`, author `github-actions[bot]`
- Release created_at 2026-07-13T17:56:40Z · published_at 2026-07-13T17:58:00Z
- Asset: `AI-Pet-Usage-alpha-v0.1.5-arm64.zip` · 1812208 bytes · sha256 `0ddcc1036c86493cce0e212b234ecce58e8bf57c3f4c28e5cb7d6622d1ffc581` · uploader `github-actions[bot]`
- Asset URL (historical): `https://github.com/F-e-u-e-r/ai-pet-usage/releases/download/alpha-v0.1.5/AI-Pet-Usage-alpha-v0.1.5-arm64.zip`
- Homebrew: `F-e-u-e-r/homebrew-tap` commit `cc9d5ad172a2c5c8def5c3a939021ad038d06666` (2026-07-13T19:46:52Z) set cask version `0.1.5`, sha256 `0ddcc1036c86493cce0e212b234ecce58e8bf57c3f4c28e5cb7d6622d1ffc581` (matches the Release asset); url template `.../releases/download/alpha-v#{version}/AI-Pet-Usage-alpha-v#{version}-arm64.zip`

Annotated tag object (verbatim):

```text
object f6c63de26c096dfc158a34160d3a3abb69eea4fc
type commit
tag alpha-v0.1.5
tagger F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com> 1783965400 +0800

alpha-v0.1.5 — release notes now render from the annotated tag

Maintenance release. The release workflow now re-fetches the annotated tag
object before reading its message, so "What's new" renders from the tag instead
of falling back to the commit history — actions/checkout had been re-fetching
the pushed tag by SHA and clobbering it into a lightweight ref. No app changes
since alpha-v0.1.4 (this is the workflow fix itself, verified end-to-end by
this release's own notes rendering).

Alpha build — Apple Silicon (arm64), ad-hoc signed, not notarized.
```

Annotated tag object (base64, 722 bytes, git tag object `7c63a9534590d5a4a35067a49193d2491aa21ef1`):

```text
b2JqZWN0IGY2YzYzZGUyNmMwOTZkZmMxNThhMzQxNjBkM2EzYWJiNjllZWE0ZmMKdHlwZSBjb21t
aXQKdGFnIGFscGhhLXYwLjEuNQp0YWdnZXIgRi1lLXUtZS1yIDwxODk0NjQzMDMrRi1lLXUtZS1y
QHVzZXJzLm5vcmVwbHkuZ2l0aHViLmNvbT4gMTc4Mzk2NTQwMCArMDgwMAoKYWxwaGEtdjAuMS41
IOKAlCByZWxlYXNlIG5vdGVzIG5vdyByZW5kZXIgZnJvbSB0aGUgYW5ub3RhdGVkIHRhZwoKTWFp
bnRlbmFuY2UgcmVsZWFzZS4gVGhlIHJlbGVhc2Ugd29ya2Zsb3cgbm93IHJlLWZldGNoZXMgdGhl
IGFubm90YXRlZCB0YWcKb2JqZWN0IGJlZm9yZSByZWFkaW5nIGl0cyBtZXNzYWdlLCBzbyAiV2hh
dCdzIG5ldyIgcmVuZGVycyBmcm9tIHRoZSB0YWcgaW5zdGVhZApvZiBmYWxsaW5nIGJhY2sgdG8g
dGhlIGNvbW1pdCBoaXN0b3J5IOKAlCBhY3Rpb25zL2NoZWNrb3V0IGhhZCBiZWVuIHJlLWZldGNo
aW5nCnRoZSBwdXNoZWQgdGFnIGJ5IFNIQSBhbmQgY2xvYmJlcmluZyBpdCBpbnRvIGEgbGlnaHR3
ZWlnaHQgcmVmLiBObyBhcHAgY2hhbmdlcwpzaW5jZSBhbHBoYS12MC4xLjQgKHRoaXMgaXMgdGhl
IHdvcmtmbG93IGZpeCBpdHNlbGYsIHZlcmlmaWVkIGVuZC10by1lbmQgYnkKdGhpcyByZWxlYXNl
J3Mgb3duIG5vdGVzIHJlbmRlcmluZykuCgpBbHBoYSBidWlsZCDigJQgQXBwbGUgU2lsaWNvbiAo
YXJtNjQpLCBhZC1ob2Mgc2lnbmVkLCBub3Qgbm90YXJpemVkLgo=
```

Release body (verbatim; 1241 bytes, sha256 `78a69d82eb6d23c9dd8e2256e74dc272c5d1c74cd592829ade3cbc60a4269afc`):

```text
## What's new

alpha-v0.1.5 — release notes now render from the annotated tag

Maintenance release. The release workflow now re-fetches the annotated tag
object before reading its message, so "What's new" renders from the tag instead
of falling back to the commit history — actions/checkout had been re-fetching
the pushed tag by SHA and clobbering it into a lightweight ref. No app changes
since alpha-v0.1.4 (this is the workflow fix itself, verified end-to-end by
this release's own notes rendering).

Alpha build — Apple Silicon (arm64), ad-hoc signed, not notarized.

## Install

Homebrew (Apple Silicon, recommended):

    brew install --cask F-e-u-e-r/tap/ai-pet-usage

Or download the arm64 zip below and drag the app to Applications.

**Alpha build — Apple Silicon (arm64), ad-hoc signed, not notarized.**
macOS blocks the first launch: open the app, then System Settings -> Privacy & Security -> **Open Anyway** (only if you trust this release).
Homebrew does not remove this one-time approval; only Developer ID notarization would.

Requirements: macOS 14+. Intel Macs: build from source (see README -> Install).
Local-first: the app reads Claude Code / Codex / Grok CLI logs on your machine; it never uploads usage data.
```

Release body (base64):

```text
IyMgV2hhdCdzIG5ldwoKYWxwaGEtdjAuMS41IOKAlCByZWxlYXNlIG5vdGVzIG5vdyByZW5kZXIg
ZnJvbSB0aGUgYW5ub3RhdGVkIHRhZwoKTWFpbnRlbmFuY2UgcmVsZWFzZS4gVGhlIHJlbGVhc2Ug
d29ya2Zsb3cgbm93IHJlLWZldGNoZXMgdGhlIGFubm90YXRlZCB0YWcKb2JqZWN0IGJlZm9yZSBy
ZWFkaW5nIGl0cyBtZXNzYWdlLCBzbyAiV2hhdCdzIG5ldyIgcmVuZGVycyBmcm9tIHRoZSB0YWcg
aW5zdGVhZApvZiBmYWxsaW5nIGJhY2sgdG8gdGhlIGNvbW1pdCBoaXN0b3J5IOKAlCBhY3Rpb25z
L2NoZWNrb3V0IGhhZCBiZWVuIHJlLWZldGNoaW5nCnRoZSBwdXNoZWQgdGFnIGJ5IFNIQSBhbmQg
Y2xvYmJlcmluZyBpdCBpbnRvIGEgbGlnaHR3ZWlnaHQgcmVmLiBObyBhcHAgY2hhbmdlcwpzaW5j
ZSBhbHBoYS12MC4xLjQgKHRoaXMgaXMgdGhlIHdvcmtmbG93IGZpeCBpdHNlbGYsIHZlcmlmaWVk
IGVuZC10by1lbmQgYnkKdGhpcyByZWxlYXNlJ3Mgb3duIG5vdGVzIHJlbmRlcmluZykuCgpBbHBo
YSBidWlsZCDigJQgQXBwbGUgU2lsaWNvbiAoYXJtNjQpLCBhZC1ob2Mgc2lnbmVkLCBub3Qgbm90
YXJpemVkLgoKIyMgSW5zdGFsbAoKSG9tZWJyZXcgKEFwcGxlIFNpbGljb24sIHJlY29tbWVuZGVk
KToKCiAgICBicmV3IGluc3RhbGwgLS1jYXNrIEYtZS11LWUtci90YXAvYWktcGV0LXVzYWdlCgpP
ciBkb3dubG9hZCB0aGUgYXJtNjQgemlwIGJlbG93IGFuZCBkcmFnIHRoZSBhcHAgdG8gQXBwbGlj
YXRpb25zLgoKKipBbHBoYSBidWlsZCDigJQgQXBwbGUgU2lsaWNvbiAoYXJtNjQpLCBhZC1ob2Mg
c2lnbmVkLCBub3Qgbm90YXJpemVkLioqCm1hY09TIGJsb2NrcyB0aGUgZmlyc3QgbGF1bmNoOiBv
cGVuIHRoZSBhcHAsIHRoZW4gU3lzdGVtIFNldHRpbmdzIC0+IFByaXZhY3kgJiBTZWN1cml0eSAt
PiAqKk9wZW4gQW55d2F5KiogKG9ubHkgaWYgeW91IHRydXN0IHRoaXMgcmVsZWFzZSkuCkhvbWVi
cmV3IGRvZXMgbm90IHJlbW92ZSB0aGlzIG9uZS10aW1lIGFwcHJvdmFsOyBvbmx5IERldmVsb3Bl
ciBJRCBub3Rhcml6YXRpb24gd291bGQuCgpSZXF1aXJlbWVudHM6IG1hY09TIDE0Ky4gSW50ZWwg
TWFjczogYnVpbGQgZnJvbSBzb3VyY2UgKHNlZSBSRUFETUUgLT4gSW5zdGFsbCkuCkxvY2FsLWZp
cnN0OiB0aGUgYXBwIHJlYWRzIENsYXVkZSBDb2RlIC8gQ29kZXggLyBHcm9rIENMSSBsb2dzIG9u
IHlvdXIgbWFjaGluZTsgaXQgbmV2ZXIgdXBsb2FkcyB1c2FnZSBkYXRhLgo=
```

### `alpha-v0.1.6`

- Tag type: annotated (tag object `ab538aea4942fbf5c8275f3371057b180e1e696b`)
- Peeled commit: `ba7d55991072831b544ffdb88f776e5bd16098f6` — "pet: reserved bubble area click-through (two-panel) + fullness % in Give Treat menu (#18)"
- Commit reachable from `main` without the tag ref: yes (ancestor of `origin/main` `936d9b1`)
- Tagger: F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com>, 2026-07-14T11:14:58Z (raw `1784027698 +0800`)
- GitHub Release: id 353744312, title "AI Pet Usage alpha-v0.1.6", draft false, prerelease true, target_commitish `main`, author `github-actions[bot]`
- Release created_at 2026-07-14T11:14:58Z · published_at 2026-07-14T11:16:19Z
- Asset: `AI-Pet-Usage-alpha-v0.1.6-arm64.zip` · 1816495 bytes · sha256 `4b01b01e7e90e0d7f2233e70e1b9d6146d19173e7f2181b60d11ba3c802aded6` · uploader `github-actions[bot]`
- Asset URL (historical): `https://github.com/F-e-u-e-r/ai-pet-usage/releases/download/alpha-v0.1.6/AI-Pet-Usage-alpha-v0.1.6-arm64.zip`
- Homebrew: `F-e-u-e-r/homebrew-tap` commit `dd182d0c7aa7d54c8962dc069aade9d169da4cb5` (2026-07-14T14:10:37Z) set cask version `0.1.6`, sha256 `4b01b01e7e90e0d7f2233e70e1b9d6146d19173e7f2181b60d11ba3c802aded6` (matches the Release asset); url template `.../releases/download/alpha-v#{version}/AI-Pet-Usage-alpha-v#{version}-arm64.zip`

Annotated tag object (verbatim):

```text
object ba7d55991072831b544ffdb88f776e5bd16098f6
type commit
tag alpha-v0.1.6
tagger F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com> 1784027698 +0800

alpha-v0.1.6 — pet bubble area click-through + fullness in Give Treat menu

The empty area above the pet (reserved for the speech bubble) now passes clicks
through to the app behind instead of swallowing them: the pet is split into a
footprint-only panel plus an always-mouse-ignoring child bubble panel, so empty
space above the pet is click-through while the pet itself stays clickable and
draggable. The right-click "Give Treat" menu now shows the pet's fullness % — a
pet under 30% is hungry and won't wander, so you can see at a glance why it may
be sitting rather than walking.

Alpha build — Apple Silicon (arm64), ad-hoc signed, not notarized.
```

Annotated tag object (base64, 817 bytes, git tag object `ab538aea4942fbf5c8275f3371057b180e1e696b`):

```text
b2JqZWN0IGJhN2Q1NTk5MTA3MjgzMWI1NDRmZmRiODhmNzc2ZTViZDE2MDk4ZjYKdHlwZSBjb21t
aXQKdGFnIGFscGhhLXYwLjEuNgp0YWdnZXIgRi1lLXUtZS1yIDwxODk0NjQzMDMrRi1lLXUtZS1y
QHVzZXJzLm5vcmVwbHkuZ2l0aHViLmNvbT4gMTc4NDAyNzY5OCArMDgwMAoKYWxwaGEtdjAuMS42
IOKAlCBwZXQgYnViYmxlIGFyZWEgY2xpY2stdGhyb3VnaCArIGZ1bGxuZXNzIGluIEdpdmUgVHJl
YXQgbWVudQoKVGhlIGVtcHR5IGFyZWEgYWJvdmUgdGhlIHBldCAocmVzZXJ2ZWQgZm9yIHRoZSBz
cGVlY2ggYnViYmxlKSBub3cgcGFzc2VzIGNsaWNrcwp0aHJvdWdoIHRvIHRoZSBhcHAgYmVoaW5k
IGluc3RlYWQgb2Ygc3dhbGxvd2luZyB0aGVtOiB0aGUgcGV0IGlzIHNwbGl0IGludG8gYQpmb290
cHJpbnQtb25seSBwYW5lbCBwbHVzIGFuIGFsd2F5cy1tb3VzZS1pZ25vcmluZyBjaGlsZCBidWJi
bGUgcGFuZWwsIHNvIGVtcHR5CnNwYWNlIGFib3ZlIHRoZSBwZXQgaXMgY2xpY2stdGhyb3VnaCB3
aGlsZSB0aGUgcGV0IGl0c2VsZiBzdGF5cyBjbGlja2FibGUgYW5kCmRyYWdnYWJsZS4gVGhlIHJp
Z2h0LWNsaWNrICJHaXZlIFRyZWF0IiBtZW51IG5vdyBzaG93cyB0aGUgcGV0J3MgZnVsbG5lc3Mg
JSDigJQgYQpwZXQgdW5kZXIgMzAlIGlzIGh1bmdyeSBhbmQgd29uJ3Qgd2FuZGVyLCBzbyB5b3Ug
Y2FuIHNlZSBhdCBhIGdsYW5jZSB3aHkgaXQgbWF5CmJlIHNpdHRpbmcgcmF0aGVyIHRoYW4gd2Fs
a2luZy4KCkFscGhhIGJ1aWxkIOKAlCBBcHBsZSBTaWxpY29uIChhcm02NCksIGFkLWhvYyBzaWdu
ZWQsIG5vdCBub3Rhcml6ZWQuCg==
```

Release body (verbatim; 1336 bytes, sha256 `c450e8da57565b33a89cabaf54e77e9aa67a3c62de1720a2a995c0f2f301d1c5`):

```text
## What's new

alpha-v0.1.6 — pet bubble area click-through + fullness in Give Treat menu

The empty area above the pet (reserved for the speech bubble) now passes clicks
through to the app behind instead of swallowing them: the pet is split into a
footprint-only panel plus an always-mouse-ignoring child bubble panel, so empty
space above the pet is click-through while the pet itself stays clickable and
draggable. The right-click "Give Treat" menu now shows the pet's fullness % — a
pet under 30% is hungry and won't wander, so you can see at a glance why it may
be sitting rather than walking.

Alpha build — Apple Silicon (arm64), ad-hoc signed, not notarized.

## Install

Homebrew (Apple Silicon, recommended):

    brew install --cask F-e-u-e-r/tap/ai-pet-usage

Or download the arm64 zip below and drag the app to Applications.

**Alpha build — Apple Silicon (arm64), ad-hoc signed, not notarized.**
macOS blocks the first launch: open the app, then System Settings -> Privacy & Security -> **Open Anyway** (only if you trust this release).
Homebrew does not remove this one-time approval; only Developer ID notarization would.

Requirements: macOS 14+. Intel Macs: build from source (see README -> Install).
Local-first: the app reads Claude Code / Codex / Grok CLI logs on your machine; it never uploads usage data.
```

Release body (base64):

```text
IyMgV2hhdCdzIG5ldwoKYWxwaGEtdjAuMS42IOKAlCBwZXQgYnViYmxlIGFyZWEgY2xpY2stdGhy
b3VnaCArIGZ1bGxuZXNzIGluIEdpdmUgVHJlYXQgbWVudQoKVGhlIGVtcHR5IGFyZWEgYWJvdmUg
dGhlIHBldCAocmVzZXJ2ZWQgZm9yIHRoZSBzcGVlY2ggYnViYmxlKSBub3cgcGFzc2VzIGNsaWNr
cwp0aHJvdWdoIHRvIHRoZSBhcHAgYmVoaW5kIGluc3RlYWQgb2Ygc3dhbGxvd2luZyB0aGVtOiB0
aGUgcGV0IGlzIHNwbGl0IGludG8gYQpmb290cHJpbnQtb25seSBwYW5lbCBwbHVzIGFuIGFsd2F5
cy1tb3VzZS1pZ25vcmluZyBjaGlsZCBidWJibGUgcGFuZWwsIHNvIGVtcHR5CnNwYWNlIGFib3Zl
IHRoZSBwZXQgaXMgY2xpY2stdGhyb3VnaCB3aGlsZSB0aGUgcGV0IGl0c2VsZiBzdGF5cyBjbGlj
a2FibGUgYW5kCmRyYWdnYWJsZS4gVGhlIHJpZ2h0LWNsaWNrICJHaXZlIFRyZWF0IiBtZW51IG5v
dyBzaG93cyB0aGUgcGV0J3MgZnVsbG5lc3MgJSDigJQgYQpwZXQgdW5kZXIgMzAlIGlzIGh1bmdy
eSBhbmQgd29uJ3Qgd2FuZGVyLCBzbyB5b3UgY2FuIHNlZSBhdCBhIGdsYW5jZSB3aHkgaXQgbWF5
CmJlIHNpdHRpbmcgcmF0aGVyIHRoYW4gd2Fsa2luZy4KCkFscGhhIGJ1aWxkIOKAlCBBcHBsZSBT
aWxpY29uIChhcm02NCksIGFkLWhvYyBzaWduZWQsIG5vdCBub3Rhcml6ZWQuCgojIyBJbnN0YWxs
CgpIb21lYnJldyAoQXBwbGUgU2lsaWNvbiwgcmVjb21tZW5kZWQpOgoKICAgIGJyZXcgaW5zdGFs
bCAtLWNhc2sgRi1lLXUtZS1yL3RhcC9haS1wZXQtdXNhZ2UKCk9yIGRvd25sb2FkIHRoZSBhcm02
NCB6aXAgYmVsb3cgYW5kIGRyYWcgdGhlIGFwcCB0byBBcHBsaWNhdGlvbnMuCgoqKkFscGhhIGJ1
aWxkIOKAlCBBcHBsZSBTaWxpY29uIChhcm02NCksIGFkLWhvYyBzaWduZWQsIG5vdCBub3Rhcml6
ZWQuKioKbWFjT1MgYmxvY2tzIHRoZSBmaXJzdCBsYXVuY2g6IG9wZW4gdGhlIGFwcCwgdGhlbiBT
eXN0ZW0gU2V0dGluZ3MgLT4gUHJpdmFjeSAmIFNlY3VyaXR5IC0+ICoqT3BlbiBBbnl3YXkqKiAo
b25seSBpZiB5b3UgdHJ1c3QgdGhpcyByZWxlYXNlKS4KSG9tZWJyZXcgZG9lcyBub3QgcmVtb3Zl
IHRoaXMgb25lLXRpbWUgYXBwcm92YWw7IG9ubHkgRGV2ZWxvcGVyIElEIG5vdGFyaXphdGlvbiB3
b3VsZC4KClJlcXVpcmVtZW50czogbWFjT1MgMTQrLiBJbnRlbCBNYWNzOiBidWlsZCBmcm9tIHNv
dXJjZSAoc2VlIFJFQURNRSAtPiBJbnN0YWxsKS4KTG9jYWwtZmlyc3Q6IHRoZSBhcHAgcmVhZHMg
Q2xhdWRlIENvZGUgLyBDb2RleCAvIEdyb2sgQ0xJIGxvZ3Mgb24geW91ciBtYWNoaW5lOyBpdCBu
ZXZlciB1cGxvYWRzIHVzYWdlIGRhdGEuCg==
```

### `alpha-v0.2.0`

- Tag type: annotated (tag object `5e62c6cae90fd0b0de889441877964df52b69334`)
- Peeled commit: `9db4dde9a6b86eef4a209c89365e75b419d0f276` — "chore(pricing): apply Sonnet 5 GA rates"
- Commit reachable from `main` without the tag ref: yes (ancestor of `origin/main` `936d9b1`)
- Tagger: F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com>, 2026-09-17T17:07:53Z (raw `1789664873 +0800`)
- GitHub Release: id 390908555, title "AI Pet Usage alpha-v0.2.0", draft false, prerelease true, target_commitish `main`, author `github-actions[bot]`
- Release created_at 2026-09-17T17:07:53Z · published_at 2026-09-17T17:12:23Z
- Asset: `AI-Pet-Usage-alpha-v0.2.0-arm64.zip` · 3068124 bytes · sha256 `509b13c3694ddc94fb01f8d5b6a39a3daddea105258e61b9c19c5a1947f0a6c1` · uploader `github-actions[bot]`
- Asset URL (historical): `https://github.com/F-e-u-e-r/ai-pet-usage/releases/download/alpha-v0.2.0/AI-Pet-Usage-alpha-v0.2.0-arm64.zip`
- Homebrew: `F-e-u-e-r/homebrew-tap` commit `5f4bff44c61e20eb33a6558b1ffebe5fe7dd84e0` (2026-09-17T17:31:43Z) set cask version `0.2.0`, sha256 `509b13c3694ddc94fb01f8d5b6a39a3daddea105258e61b9c19c5a1947f0a6c1` (matches the Release asset); url template `.../releases/download/alpha-v#{version}/AI-Pet-Usage-alpha-v#{version}-arm64.zip`

Annotated tag object (verbatim):

```text
object 9db4dde9a6b86eef4a209c89365e75b419d0f276
type commit
tag alpha-v0.2.0
tagger F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com> 1789664873 +0800

- Provider-reported limits are now separated from local usage — Claude shows account-level official 5h/weekly percentages, while local budget estimates never masquerade as provider-reported values
- Major memory and retention improvements — eliminates the repeated compaction-driven RAM regrowth that could leave long-running sessions around 1+ GB, with logical retention and batched physical compaction
- Trust layer improvements: Data Health, verified provider status where available, honest quota-reset celebrations, and sink-side redaction
- Added OpenCode usage support and an opt-in OpenRouter prepaid-credits monitor
- Added `aipet install-hook` for one-command Claude statusline setup, including `--wrap` support for existing statuslines, plus redacted `aipet diag` export
- Durability hardening across ledger persistence, monotonic replacement, replay-safe reconciliation, and filesystem commit barriers
- Dashboard and menu improvements, including weekly percentage visibility, aligned provider rows, and triple-digit percentage display fixes
```

Annotated tag object (base64, 1216 bytes, git tag object `5e62c6cae90fd0b0de889441877964df52b69334`):

```text
b2JqZWN0IDlkYjRkZGU5YTZiODZlZWY0YTIwOWM4OTM2NWU3NWI0MTlkMGYyNzYKdHlwZSBjb21t
aXQKdGFnIGFscGhhLXYwLjIuMAp0YWdnZXIgRi1lLXUtZS1yIDwxODk0NjQzMDMrRi1lLXUtZS1y
QHVzZXJzLm5vcmVwbHkuZ2l0aHViLmNvbT4gMTc4OTY2NDg3MyArMDgwMAoKLSBQcm92aWRlci1y
ZXBvcnRlZCBsaW1pdHMgYXJlIG5vdyBzZXBhcmF0ZWQgZnJvbSBsb2NhbCB1c2FnZSDigJQgQ2xh
dWRlIHNob3dzIGFjY291bnQtbGV2ZWwgb2ZmaWNpYWwgNWgvd2Vla2x5IHBlcmNlbnRhZ2VzLCB3
aGlsZSBsb2NhbCBidWRnZXQgZXN0aW1hdGVzIG5ldmVyIG1hc3F1ZXJhZGUgYXMgcHJvdmlkZXIt
cmVwb3J0ZWQgdmFsdWVzCi0gTWFqb3IgbWVtb3J5IGFuZCByZXRlbnRpb24gaW1wcm92ZW1lbnRz
IOKAlCBlbGltaW5hdGVzIHRoZSByZXBlYXRlZCBjb21wYWN0aW9uLWRyaXZlbiBSQU0gcmVncm93
dGggdGhhdCBjb3VsZCBsZWF2ZSBsb25nLXJ1bm5pbmcgc2Vzc2lvbnMgYXJvdW5kIDErIEdCLCB3
aXRoIGxvZ2ljYWwgcmV0ZW50aW9uIGFuZCBiYXRjaGVkIHBoeXNpY2FsIGNvbXBhY3Rpb24KLSBU
cnVzdCBsYXllciBpbXByb3ZlbWVudHM6IERhdGEgSGVhbHRoLCB2ZXJpZmllZCBwcm92aWRlciBz
dGF0dXMgd2hlcmUgYXZhaWxhYmxlLCBob25lc3QgcXVvdGEtcmVzZXQgY2VsZWJyYXRpb25zLCBh
bmQgc2luay1zaWRlIHJlZGFjdGlvbgotIEFkZGVkIE9wZW5Db2RlIHVzYWdlIHN1cHBvcnQgYW5k
IGFuIG9wdC1pbiBPcGVuUm91dGVyIHByZXBhaWQtY3JlZGl0cyBtb25pdG9yCi0gQWRkZWQgYGFp
cGV0IGluc3RhbGwtaG9va2AgZm9yIG9uZS1jb21tYW5kIENsYXVkZSBzdGF0dXNsaW5lIHNldHVw
LCBpbmNsdWRpbmcgYC0td3JhcGAgc3VwcG9ydCBmb3IgZXhpc3Rpbmcgc3RhdHVzbGluZXMsIHBs
dXMgcmVkYWN0ZWQgYGFpcGV0IGRpYWdgIGV4cG9ydAotIER1cmFiaWxpdHkgaGFyZGVuaW5nIGFj
cm9zcyBsZWRnZXIgcGVyc2lzdGVuY2UsIG1vbm90b25pYyByZXBsYWNlbWVudCwgcmVwbGF5LXNh
ZmUgcmVjb25jaWxpYXRpb24sIGFuZCBmaWxlc3lzdGVtIGNvbW1pdCBiYXJyaWVycwotIERhc2hi
b2FyZCBhbmQgbWVudSBpbXByb3ZlbWVudHMsIGluY2x1ZGluZyB3ZWVrbHkgcGVyY2VudGFnZSB2
aXNpYmlsaXR5LCBhbGlnbmVkIHByb3ZpZGVyIHJvd3MsIGFuZCB0cmlwbGUtZGlnaXQgcGVyY2Vu
dGFnZSBkaXNwbGF5IGZpeGVzCg==
```

Release body (verbatim; 1735 bytes, sha256 `d487d676c64e994a5b8dc9a1f0901b227aacb8f9fa1f00353532f02dba27739a`):

```text
## What's new

- Provider-reported limits are now separated from local usage — Claude shows account-level official 5h/weekly percentages, while local budget estimates never masquerade as provider-reported values
- Major memory and retention improvements — eliminates the repeated compaction-driven RAM regrowth that could leave long-running sessions around 1+ GB, with logical retention and batched physical compaction
- Trust layer improvements: Data Health, verified provider status where available, honest quota-reset celebrations, and sink-side redaction
- Added OpenCode usage support and an opt-in OpenRouter prepaid-credits monitor
- Added `aipet install-hook` for one-command Claude statusline setup, including `--wrap` support for existing statuslines, plus redacted `aipet diag` export
- Durability hardening across ledger persistence, monotonic replacement, replay-safe reconciliation, and filesystem commit barriers
- Dashboard and menu improvements, including weekly percentage visibility, aligned provider rows, and triple-digit percentage display fixes

## Install

Homebrew (Apple Silicon, recommended):

    brew install --cask F-e-u-e-r/tap/ai-pet-usage

Or download the arm64 zip below and drag the app to Applications.

**Alpha build — Apple Silicon (arm64), ad-hoc signed, not notarized.**
macOS blocks the first launch: open the app, then System Settings -> Privacy & Security -> **Open Anyway** (only if you trust this release).
Homebrew does not remove this one-time approval; only Developer ID notarization would.

Requirements: macOS 14+. Intel Macs: build from source (see README -> Install).
Local-first: the app reads Claude Code / Codex / Grok CLI logs on your machine; it never uploads usage data.
```

Release body (base64):

```text
IyMgV2hhdCdzIG5ldwoKLSBQcm92aWRlci1yZXBvcnRlZCBsaW1pdHMgYXJlIG5vdyBzZXBhcmF0
ZWQgZnJvbSBsb2NhbCB1c2FnZSDigJQgQ2xhdWRlIHNob3dzIGFjY291bnQtbGV2ZWwgb2ZmaWNp
YWwgNWgvd2Vla2x5IHBlcmNlbnRhZ2VzLCB3aGlsZSBsb2NhbCBidWRnZXQgZXN0aW1hdGVzIG5l
dmVyIG1hc3F1ZXJhZGUgYXMgcHJvdmlkZXItcmVwb3J0ZWQgdmFsdWVzCi0gTWFqb3IgbWVtb3J5
IGFuZCByZXRlbnRpb24gaW1wcm92ZW1lbnRzIOKAlCBlbGltaW5hdGVzIHRoZSByZXBlYXRlZCBj
b21wYWN0aW9uLWRyaXZlbiBSQU0gcmVncm93dGggdGhhdCBjb3VsZCBsZWF2ZSBsb25nLXJ1bm5p
bmcgc2Vzc2lvbnMgYXJvdW5kIDErIEdCLCB3aXRoIGxvZ2ljYWwgcmV0ZW50aW9uIGFuZCBiYXRj
aGVkIHBoeXNpY2FsIGNvbXBhY3Rpb24KLSBUcnVzdCBsYXllciBpbXByb3ZlbWVudHM6IERhdGEg
SGVhbHRoLCB2ZXJpZmllZCBwcm92aWRlciBzdGF0dXMgd2hlcmUgYXZhaWxhYmxlLCBob25lc3Qg
cXVvdGEtcmVzZXQgY2VsZWJyYXRpb25zLCBhbmQgc2luay1zaWRlIHJlZGFjdGlvbgotIEFkZGVk
IE9wZW5Db2RlIHVzYWdlIHN1cHBvcnQgYW5kIGFuIG9wdC1pbiBPcGVuUm91dGVyIHByZXBhaWQt
Y3JlZGl0cyBtb25pdG9yCi0gQWRkZWQgYGFpcGV0IGluc3RhbGwtaG9va2AgZm9yIG9uZS1jb21t
YW5kIENsYXVkZSBzdGF0dXNsaW5lIHNldHVwLCBpbmNsdWRpbmcgYC0td3JhcGAgc3VwcG9ydCBm
b3IgZXhpc3Rpbmcgc3RhdHVzbGluZXMsIHBsdXMgcmVkYWN0ZWQgYGFpcGV0IGRpYWdgIGV4cG9y
dAotIER1cmFiaWxpdHkgaGFyZGVuaW5nIGFjcm9zcyBsZWRnZXIgcGVyc2lzdGVuY2UsIG1vbm90
b25pYyByZXBsYWNlbWVudCwgcmVwbGF5LXNhZmUgcmVjb25jaWxpYXRpb24sIGFuZCBmaWxlc3lz
dGVtIGNvbW1pdCBiYXJyaWVycwotIERhc2hib2FyZCBhbmQgbWVudSBpbXByb3ZlbWVudHMsIGlu
Y2x1ZGluZyB3ZWVrbHkgcGVyY2VudGFnZSB2aXNpYmlsaXR5LCBhbGlnbmVkIHByb3ZpZGVyIHJv
d3MsIGFuZCB0cmlwbGUtZGlnaXQgcGVyY2VudGFnZSBkaXNwbGF5IGZpeGVzCgojIyBJbnN0YWxs
CgpIb21lYnJldyAoQXBwbGUgU2lsaWNvbiwgcmVjb21tZW5kZWQpOgoKICAgIGJyZXcgaW5zdGFs
bCAtLWNhc2sgRi1lLXUtZS1yL3RhcC9haS1wZXQtdXNhZ2UKCk9yIGRvd25sb2FkIHRoZSBhcm02
NCB6aXAgYmVsb3cgYW5kIGRyYWcgdGhlIGFwcCB0byBBcHBsaWNhdGlvbnMuCgoqKkFscGhhIGJ1
aWxkIOKAlCBBcHBsZSBTaWxpY29uIChhcm02NCksIGFkLWhvYyBzaWduZWQsIG5vdCBub3Rhcml6
ZWQuKioKbWFjT1MgYmxvY2tzIHRoZSBmaXJzdCBsYXVuY2g6IG9wZW4gdGhlIGFwcCwgdGhlbiBT
eXN0ZW0gU2V0dGluZ3MgLT4gUHJpdmFjeSAmIFNlY3VyaXR5IC0+ICoqT3BlbiBBbnl3YXkqKiAo
b25seSBpZiB5b3UgdHJ1c3QgdGhpcyByZWxlYXNlKS4KSG9tZWJyZXcgZG9lcyBub3QgcmVtb3Zl
IHRoaXMgb25lLXRpbWUgYXBwcm92YWw7IG9ubHkgRGV2ZWxvcGVyIElEIG5vdGFyaXphdGlvbiB3
b3VsZC4KClJlcXVpcmVtZW50czogbWFjT1MgMTQrLiBJbnRlbCBNYWNzOiBidWlsZCBmcm9tIHNv
dXJjZSAoc2VlIFJFQURNRSAtPiBJbnN0YWxsKS4KTG9jYWwtZmlyc3Q6IHRoZSBhcHAgcmVhZHMg
Q2xhdWRlIENvZGUgLyBDb2RleCAvIEdyb2sgQ0xJIGxvZ3Mgb24geW91ciBtYWNoaW5lOyBpdCBu
ZXZlciB1cGxvYWRzIHVzYWdlIGRhdGEuCg==
```

### `alpha-v0.3.0`

- Tag type: annotated (tag object `28a2ca23a9bdda7066fa7d5ef0a33b51c01909db`)
- Peeled commit: `b7c4b72ee0af40621ccd30f4efd8389927b41ab0` — "feat(usage): add project model hover preview (#107)"
- Commit reachable from `main` without the tag ref: yes (ancestor of `origin/main` `936d9b1`)
- Tagger: F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com>, 2026-09-25T18:06:52Z (raw `1790359612 +0800`)
- GitHub Release: id 396824160, title "AI Pet Usage alpha-v0.3.0", draft false, prerelease true, target_commitish `main`, author `github-actions[bot]`
- Release created_at 2026-09-25T18:06:52Z · published_at 2026-09-25T18:08:52Z
- Asset: `AI-Pet-Usage-alpha-v0.3.0-arm64.zip` · 3218604 bytes · sha256 `87e4a061588bb8b101fd84929e15d0b15c77fe5facb0f810d06395b82f636c8a` · uploader `github-actions[bot]`
- Asset URL (historical): `https://github.com/F-e-u-e-r/ai-pet-usage/releases/download/alpha-v0.3.0/AI-Pet-Usage-alpha-v0.3.0-arm64.zip`
- Homebrew: `F-e-u-e-r/homebrew-tap` commit `ec541f2edeebdbea77d36d41e06323abfbea9b7b` (2026-09-25T21:31:49Z) set cask version `0.3.0`, sha256 `87e4a061588bb8b101fd84929e15d0b15c77fe5facb0f810d06395b82f636c8a` (matches the Release asset); url template `.../releases/download/alpha-v#{version}/AI-Pet-Usage-alpha-v#{version}-arm64.zip`

Annotated tag object (verbatim):

```text
object b7c4b72ee0af40621ccd30f4efd8389927b41ab0
type commit
tag alpha-v0.3.0
tagger F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com> 1790359612 +0800

AI Pet Usage alpha v0.3.0
```

Annotated tag object (base64, 185 bytes, git tag object `28a2ca23a9bdda7066fa7d5ef0a33b51c01909db`):

```text
b2JqZWN0IGI3YzRiNzJlZTBhZjQwNjIxY2NkMzBmNGVmZDgzODk5MjdiNDFhYjAKdHlwZSBjb21t
aXQKdGFnIGFscGhhLXYwLjMuMAp0YWdnZXIgRi1lLXUtZS1yIDwxODk0NjQzMDMrRi1lLXUtZS1y
QHVzZXJzLm5vcmVwbHkuZ2l0aHViLmNvbT4gMTc5MDM1OTYxMiArMDgwMAoKQUkgUGV0IFVzYWdl
IGFscGhhIHYwLjMuMAo=
```

Release body (verbatim; 704 bytes, sha256 `64b4c496c9a5a9beff5d1c218bd24a587edebb830eefd1eadffd834a2e4a043c`):

```text
## What's new

AI Pet Usage alpha v0.3.0

## Install

Homebrew (Apple Silicon, recommended):

    brew install --cask F-e-u-e-r/tap/ai-pet-usage

Or download the arm64 zip below and drag the app to Applications.

**Alpha build — Apple Silicon (arm64), ad-hoc signed, not notarized.**
macOS blocks the first launch: open the app, then System Settings -> Privacy & Security -> **Open Anyway** (only if you trust this release).
Homebrew does not remove this one-time approval; only Developer ID notarization would.

Requirements: macOS 14+. Intel Macs: build from source (see README -> Install).
Local-first: the app reads Claude Code / Codex / Grok CLI logs on your machine; it never uploads usage data.
```

Release body (base64):

```text
IyMgV2hhdCdzIG5ldwoKQUkgUGV0IFVzYWdlIGFscGhhIHYwLjMuMAoKIyMgSW5zdGFsbAoKSG9t
ZWJyZXcgKEFwcGxlIFNpbGljb24sIHJlY29tbWVuZGVkKToKCiAgICBicmV3IGluc3RhbGwgLS1j
YXNrIEYtZS11LWUtci90YXAvYWktcGV0LXVzYWdlCgpPciBkb3dubG9hZCB0aGUgYXJtNjQgemlw
IGJlbG93IGFuZCBkcmFnIHRoZSBhcHAgdG8gQXBwbGljYXRpb25zLgoKKipBbHBoYSBidWlsZCDi
gJQgQXBwbGUgU2lsaWNvbiAoYXJtNjQpLCBhZC1ob2Mgc2lnbmVkLCBub3Qgbm90YXJpemVkLioq
Cm1hY09TIGJsb2NrcyB0aGUgZmlyc3QgbGF1bmNoOiBvcGVuIHRoZSBhcHAsIHRoZW4gU3lzdGVt
IFNldHRpbmdzIC0+IFByaXZhY3kgJiBTZWN1cml0eSAtPiAqKk9wZW4gQW55d2F5KiogKG9ubHkg
aWYgeW91IHRydXN0IHRoaXMgcmVsZWFzZSkuCkhvbWVicmV3IGRvZXMgbm90IHJlbW92ZSB0aGlz
IG9uZS10aW1lIGFwcHJvdmFsOyBvbmx5IERldmVsb3BlciBJRCBub3Rhcml6YXRpb24gd291bGQu
CgpSZXF1aXJlbWVudHM6IG1hY09TIDE0Ky4gSW50ZWwgTWFjczogYnVpbGQgZnJvbSBzb3VyY2Ug
KHNlZSBSRUFETUUgLT4gSW5zdGFsbCkuCkxvY2FsLWZpcnN0OiB0aGUgYXBwIHJlYWRzIENsYXVk
ZSBDb2RlIC8gQ29kZXggLyBHcm9rIENMSSBsb2dzIG9uIHlvdXIgbWFjaGluZTsgaXQgbmV2ZXIg
dXBsb2FkcyB1c2FnZSBkYXRhLgo=
```

### `alpha-v0.4.0`

- Tag type: annotated (tag object `24b8eb22ecdeee2e6f368ea09c4ed02ab8e98af0`)
- Peeled commit: `56954a10d47b14e7af125f8ea7a6decab3486442` — "feat(usage): add standalone Models tab (#108)"
- Commit reachable from `main` without the tag ref: yes (ancestor of `origin/main` `936d9b1`)
- Tagger: F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com>, 2026-09-27T17:03:45Z (raw `1790528625 +0800`)
- GitHub Release: id 397735795, title "AI Pet Usage alpha-v0.4.0", draft false, prerelease true, target_commitish `main`, author `github-actions[bot]`
- Release created_at 2026-09-27T17:03:45Z · published_at 2026-09-27T17:07:34Z
- Asset: `AI-Pet-Usage-alpha-v0.4.0-arm64.zip` · 3241989 bytes · sha256 `b5008d850d116b1150ac11b70562cdcda876a3dac90bfe74b920cfbffff3f9ab` · uploader `github-actions[bot]`
- Asset URL (historical): `https://github.com/F-e-u-e-r/ai-pet-usage/releases/download/alpha-v0.4.0/AI-Pet-Usage-alpha-v0.4.0-arm64.zip`
- Homebrew: `F-e-u-e-r/homebrew-tap` commit `de56a70843fb74d44036fd6b283b9a8eed70ebc0` (2026-09-27T21:18:09Z) set cask version `0.4.0`, sha256 `b5008d850d116b1150ac11b70562cdcda876a3dac90bfe74b920cfbffff3f9ab` (matches the Release asset); url template `.../releases/download/alpha-v#{version}/AI-Pet-Usage-alpha-v#{version}-arm64.zip`

Annotated tag object (verbatim):

```text
object 56954a10d47b14e7af125f8ea7a6decab3486442
type commit
tag alpha-v0.4.0
tagger F-e-u-e-r <189464303+F-e-u-e-r@users.noreply.github.com> 1790528625 +0800

- New Models tab: per-model usage across all providers with its own date range (Today, Yesterday, Last 7 days, This week, Last week, All time, Custom) and period totals for tokens, estimated cost and model count
- Models are grouped by provider with Input / Output / Cache / Total / Est. cost and a Provider share column (share of that provider's tokens in the range)
- Projects page simplified: its Models tile and By model table moved to the new tab, so it does less work per refresh; a project's model breakdown is still one hover away
- Export from the Models tab follows the Models range
```

Annotated tag object (base64, 752 bytes, git tag object `24b8eb22ecdeee2e6f368ea09c4ed02ab8e98af0`):

```text
b2JqZWN0IDU2OTU0YTEwZDQ3YjE0ZTdhZjEyNWY4ZWE3YTZkZWNhYjM0ODY0NDIKdHlwZSBjb21t
aXQKdGFnIGFscGhhLXYwLjQuMAp0YWdnZXIgRi1lLXUtZS1yIDwxODk0NjQzMDMrRi1lLXUtZS1y
QHVzZXJzLm5vcmVwbHkuZ2l0aHViLmNvbT4gMTc5MDUyODYyNSArMDgwMAoKLSBOZXcgTW9kZWxz
IHRhYjogcGVyLW1vZGVsIHVzYWdlIGFjcm9zcyBhbGwgcHJvdmlkZXJzIHdpdGggaXRzIG93biBk
YXRlIHJhbmdlIChUb2RheSwgWWVzdGVyZGF5LCBMYXN0IDcgZGF5cywgVGhpcyB3ZWVrLCBMYXN0
IHdlZWssIEFsbCB0aW1lLCBDdXN0b20pIGFuZCBwZXJpb2QgdG90YWxzIGZvciB0b2tlbnMsIGVz
dGltYXRlZCBjb3N0IGFuZCBtb2RlbCBjb3VudAotIE1vZGVscyBhcmUgZ3JvdXBlZCBieSBwcm92
aWRlciB3aXRoIElucHV0IC8gT3V0cHV0IC8gQ2FjaGUgLyBUb3RhbCAvIEVzdC4gY29zdCBhbmQg
YSBQcm92aWRlciBzaGFyZSBjb2x1bW4gKHNoYXJlIG9mIHRoYXQgcHJvdmlkZXIncyB0b2tlbnMg
aW4gdGhlIHJhbmdlKQotIFByb2plY3RzIHBhZ2Ugc2ltcGxpZmllZDogaXRzIE1vZGVscyB0aWxl
IGFuZCBCeSBtb2RlbCB0YWJsZSBtb3ZlZCB0byB0aGUgbmV3IHRhYiwgc28gaXQgZG9lcyBsZXNz
IHdvcmsgcGVyIHJlZnJlc2g7IGEgcHJvamVjdCdzIG1vZGVsIGJyZWFrZG93biBpcyBzdGlsbCBv
bmUgaG92ZXIgYXdheQotIEV4cG9ydCBmcm9tIHRoZSBNb2RlbHMgdGFiIGZvbGxvd3MgdGhlIE1v
ZGVscyByYW5nZQo=
```

Release body (verbatim; 1271 bytes, sha256 `f0ad28378a7b8c77627dd9dcd69a31896de21276c888305d771f2791f47b9b57`):

```text
## What's new

- New Models tab: per-model usage across all providers with its own date range (Today, Yesterday, Last 7 days, This week, Last week, All time, Custom) and period totals for tokens, estimated cost and model count
- Models are grouped by provider with Input / Output / Cache / Total / Est. cost and a Provider share column (share of that provider's tokens in the range)
- Projects page simplified: its Models tile and By model table moved to the new tab, so it does less work per refresh; a project's model breakdown is still one hover away
- Export from the Models tab follows the Models range

## Install

Homebrew (Apple Silicon, recommended):

    brew install --cask F-e-u-e-r/tap/ai-pet-usage

Or download the arm64 zip below and drag the app to Applications.

**Alpha build — Apple Silicon (arm64), ad-hoc signed, not notarized.**
macOS blocks the first launch: open the app, then System Settings -> Privacy & Security -> **Open Anyway** (only if you trust this release).
Homebrew does not remove this one-time approval; only Developer ID notarization would.

Requirements: macOS 14+. Intel Macs: build from source (see README -> Install).
Local-first: the app reads Claude Code / Codex / Grok CLI logs on your machine; it never uploads usage data.
```

Release body (base64):

```text
IyMgV2hhdCdzIG5ldwoKLSBOZXcgTW9kZWxzIHRhYjogcGVyLW1vZGVsIHVzYWdlIGFjcm9zcyBh
bGwgcHJvdmlkZXJzIHdpdGggaXRzIG93biBkYXRlIHJhbmdlIChUb2RheSwgWWVzdGVyZGF5LCBM
YXN0IDcgZGF5cywgVGhpcyB3ZWVrLCBMYXN0IHdlZWssIEFsbCB0aW1lLCBDdXN0b20pIGFuZCBw
ZXJpb2QgdG90YWxzIGZvciB0b2tlbnMsIGVzdGltYXRlZCBjb3N0IGFuZCBtb2RlbCBjb3VudAot
IE1vZGVscyBhcmUgZ3JvdXBlZCBieSBwcm92aWRlciB3aXRoIElucHV0IC8gT3V0cHV0IC8gQ2Fj
aGUgLyBUb3RhbCAvIEVzdC4gY29zdCBhbmQgYSBQcm92aWRlciBzaGFyZSBjb2x1bW4gKHNoYXJl
IG9mIHRoYXQgcHJvdmlkZXIncyB0b2tlbnMgaW4gdGhlIHJhbmdlKQotIFByb2plY3RzIHBhZ2Ug
c2ltcGxpZmllZDogaXRzIE1vZGVscyB0aWxlIGFuZCBCeSBtb2RlbCB0YWJsZSBtb3ZlZCB0byB0
aGUgbmV3IHRhYiwgc28gaXQgZG9lcyBsZXNzIHdvcmsgcGVyIHJlZnJlc2g7IGEgcHJvamVjdCdz
IG1vZGVsIGJyZWFrZG93biBpcyBzdGlsbCBvbmUgaG92ZXIgYXdheQotIEV4cG9ydCBmcm9tIHRo
ZSBNb2RlbHMgdGFiIGZvbGxvd3MgdGhlIE1vZGVscyByYW5nZQoKIyMgSW5zdGFsbAoKSG9tZWJy
ZXcgKEFwcGxlIFNpbGljb24sIHJlY29tbWVuZGVkKToKCiAgICBicmV3IGluc3RhbGwgLS1jYXNr
IEYtZS11LWUtci90YXAvYWktcGV0LXVzYWdlCgpPciBkb3dubG9hZCB0aGUgYXJtNjQgemlwIGJl
bG93IGFuZCBkcmFnIHRoZSBhcHAgdG8gQXBwbGljYXRpb25zLgoKKipBbHBoYSBidWlsZCDigJQg
QXBwbGUgU2lsaWNvbiAoYXJtNjQpLCBhZC1ob2Mgc2lnbmVkLCBub3Qgbm90YXJpemVkLioqCm1h
Y09TIGJsb2NrcyB0aGUgZmlyc3QgbGF1bmNoOiBvcGVuIHRoZSBhcHAsIHRoZW4gU3lzdGVtIFNl
dHRpbmdzIC0+IFByaXZhY3kgJiBTZWN1cml0eSAtPiAqKk9wZW4gQW55d2F5KiogKG9ubHkgaWYg
eW91IHRydXN0IHRoaXMgcmVsZWFzZSkuCkhvbWVicmV3IGRvZXMgbm90IHJlbW92ZSB0aGlzIG9u
ZS10aW1lIGFwcHJvdmFsOyBvbmx5IERldmVsb3BlciBJRCBub3Rhcml6YXRpb24gd291bGQuCgpS
ZXF1aXJlbWVudHM6IG1hY09TIDE0Ky4gSW50ZWwgTWFjczogYnVpbGQgZnJvbSBzb3VyY2UgKHNl
ZSBSRUFETUUgLT4gSW5zdGFsbCkuCkxvY2FsLWZpcnN0OiB0aGUgYXBwIHJlYWRzIENsYXVkZSBD
b2RlIC8gQ29kZXggLyBHcm9rIENMSSBsb2dzIG9uIHlvdXIgbWFjaGluZTsgaXQgbmV2ZXIgdXBs
b2FkcyB1c2FnZSBkYXRhLgo=
```

## Homebrew cask history (`F-e-u-e-r/homebrew-tap`, `Casks/ai-pet-usage.rb`)

| Tap commit | Date | Cask version | sha256 | Equals Release asset digest |
|---|---|---|---|---|
| `bc992f4501304785996b44dfb32ece112c268157` | 2026-07-13T14:19:15+08:00 | `0.1.2` | `a64757be9a6d207d418ab3b7d1cd69cd7887b3fcaf5f5ff7f285621ed8f0c77a` | yes |
| `1892a93659f02d66a1793b46606e7df9c3567264` | 2026-07-13T15:48:12+08:00 | `0.1.2` | `a64757be9a6d207d418ab3b7d1cd69cd7887b3fcaf5f5ff7f285621ed8f0c77a` | yes |
| `e588c52550d4ecf312853d01d160a41d2393f22f` | 2026-07-13T15:09:37Z | `0.1.3` | `9ff374bc3617e1cf7204ffe310c1f5b1ff9754d5b8e24f15c52b717221b3281d` | yes |
| `cc9d5ad172a2c5c8def5c3a939021ad038d06666` | 2026-07-13T19:46:52Z | `0.1.5` | `0ddcc1036c86493cce0e212b234ecce58e8bf57c3f4c28e5cb7d6622d1ffc581` | yes |
| `dd182d0c7aa7d54c8962dc069aade9d169da4cb5` | 2026-07-14T14:10:37Z | `0.1.6` | `4b01b01e7e90e0d7f2233e70e1b9d6146d19173e7f2181b60d11ba3c802aded6` | yes |
| `5f4bff44c61e20eb33a6558b1ffebe5fe7dd84e0` | 2026-09-17T17:31:43Z | `0.2.0` | `509b13c3694ddc94fb01f8d5b6a39a3daddea105258e61b9c19c5a1947f0a6c1` | yes |
| `ec541f2edeebdbea77d36d41e06323abfbea9b7b` | 2026-09-25T21:31:49Z | `0.3.0` | `87e4a061588bb8b101fd84929e15d0b15c77fe5facb0f810d06395b82f636c8a` | yes |
| `de56a70843fb74d44036fd6b283b9a8eed70ebc0` | 2026-09-27T21:18:09Z | `0.4.0` | `b5008d850d116b1150ac11b70562cdcda876a3dac90bfe74b920cfbffff3f9ab` | yes |

Every cask revision used the URL template
`https://github.com/F-e-u-e-r/ai-pet-usage/releases/download/alpha-v#{version}/AI-Pet-Usage-alpha-v#{version}-arm64.zip`.
The first two rows are the initial cask commit and a later edit that kept version `0.1.2`.
