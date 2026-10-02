#!/bin/bash
# Makes the highest canonical STABLE release "Latest" after a stable publish (docs/release/VERSIONING.md).
#
#   reconcile-latest.sh <owner/repo> <just-published stable tag>
#       env: RECONCILE_ATTEMPTS (default 10), RECONCILE_SETTLE_S (default 3), RECONCILE_RETRY_S (default 5)
#
# Detect-and-retry, confirming AFTER its own write: list the published stable releases, mark the highest canonical
# one Latest when it is not already, then re-list and re-read Latest; finish only when a fresh listing still names the
# same highest stable AND Latest equals it, otherwise repeat. A concurrent run whose stale write lands after ours
# re-lists after that write, sees the higher release and corrects it, so once every run has finished Latest is the
# highest canonical stable. (A run that dies between a write and its confirmation can leave Latest stale until the next
# stable publish; that run is then red.)
#
# Uses gh (`release list`, `api .../releases/latest`, `release edit --latest`) and release-version.sh --highest-stable.
# The listing is bounded at LIST_BOUND stable releases and asks for one more, so a listing over the bound is KNOWN to
# be incomplete and counts as a failed listing.
# Exit status: 0 = confirmed; 1 = not confirmed after every attempt; 2 = invalid usage or tag, or a failed or
# over-the-bound listing (a partial listing could crown a lower version, so nothing is ever decided from one).
set -euo pipefail
export LC_ALL=C

die() {
    printf 'reconcile-latest: %s\n' "$1" >&2
    exit "${2:-2}"
}

[ $# -eq 2 ] || die "usage: reconcile-latest.sh <owner/repo> <stable tag>"
repo="$1"
tag="$2"
RV="$(dirname "$0")/release-version.sh"
[ "$("$RV" "$tag" 2>/dev/null | sed -n 's/^RELEASE_CHANNEL=//p')" = stable ] || die "not a canonical stable tag: $tag"
attempts="${RECONCILE_ATTEMPTS:-10}"
settle="${RECONCILE_SETTLE_S:-3}"
retry="${RECONCILE_RETRY_S:-5}"
LIST_BOUND=1000

highest() {
    local list
    list="$(gh release list --repo "$repo" --limit "$((LIST_BOUND + 1))" --exclude-drafts --exclude-pre-releases \
        --json tagName --jq '.[].tagName')" || die "release listing failed"
    [ "$(printf '%s' "$list" | grep -c '')" -le "$LIST_BOUND" ] \
        || die "more than $LIST_BOUND stable releases: the listing would be incomplete"
    { printf '%s\n' "$list"; printf '%s\n' "$tag"; } | "$RV" --highest-stable
}

latest() {
    gh api "repos/$repo/releases/latest" --jq .tag_name 2>/dev/null || true
}

for ((i = 1; i <= attempts; i++)); do
    want="$(highest)"
    if [ "$(latest)" != "$want" ]; then
        gh release edit "$want" --repo "$repo" --latest >/dev/null || true   # verified below either way
    fi
    sleep "$settle"
    # Confirm after our own write: the listing must still name the same highest stable and Latest must equal it.
    if [ "$(highest)" = "$want" ] && [ "$(latest)" = "$want" ]; then
        printf 'Latest = %s\n' "$want"
        exit 0
    fi
    sleep "$retry"
done
die "Latest not confirmed after $attempts attempts" 1
