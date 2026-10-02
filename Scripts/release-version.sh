#!/bin/bash
# Canonical release version resolver — the single bash implementation of the release grammar
# (normative contract: docs/release/VERSIONING.md). Used by .github/workflows/release-app.yml and
# Scripts/write-info-plist.sh. Swift twin: Sources/UsageCore/CanonicalVersion.swift; usagecore-tests
# (CanonicalVersionTests) runs this script over every vector in
# Sources/usagecore-tests/Fixtures/canonical-version-vectors.tsv to keep both implementations identical.
#
# Grammar:  v MAJOR . MINOR . PATCH [ - (alpha|beta|rc) . N ]
#   ASCII digits only; no leading zeros (single "0" allowed for MAJOR/MINOR/PATCH); N >= 1;
#   every numeric field at most 9 digits (implementation bound shared with Swift and the tap's jq);
#   lowercase channels only; no build metadata; no other prerelease identifiers.
#   The retired legacy `alpha-vX.Y.Z` namespace is rejected.
#
# Usage:
#   release-version.sh <tag>
#       Resolve. Prints exactly these KEY=VALUE lines:
#       RELEASE_TAG, VERSION (X.Y.Z), RELEASE_CHANNEL (alpha|beta|rc|stable),
#       RELEASE_ITERATION (N, empty for stable), PRERELEASE (true|false),
#       DISPLAY_VERSION (tag without "v"), ASSET_NAME (AI-Pet-Usage-<tag>-arm64.zip)
#   release-version.sh --sort-key <tag>
#       Fixed-width key; plain lexical order of keys == canonical semantic order.
#   release-version.sh --gh-release-flags <tag> <true|false>
#       Flags for `gh release create`. Second argument: is <tag> the highest published canonical stable?
#       alpha/beta/rc -> "--prerelease --latest=false"; stable -> "--latest=true" or "--latest=false".
#   release-version.sh --highest-stable
#       Reads tag names on stdin (one per line) and prints the highest canonical STABLE tag by canonical
#       order, or nothing when there is none. Legacy, malformed and prerelease tags are ignored.
#   release-version.sh --check-build-env
#       Validates VERSION / BUILD_CHANNEL / RELEASE_TAG from the environment (Info.plist invariants):
#       VERSION must be X.Y.Z; BUILD_CHANNEL must be release|source|dev; release => RELEASE_TAG canonical
#       and its X.Y.Z == VERSION; source|dev => RELEASE_TAG empty.
# Exit status: 0 = OK; 2 = rejected or invalid usage (nothing is printed on stdout in that case).
set -euo pipefail
export LC_ALL=C

RE='^v(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})(-(alpha|beta|rc)\.([1-9][0-9]{0,8}))?$'

die() {
    printf 'release-version: %s\n' "$1" >&2
    exit 2
}

# parse <tag> -> sets MAJ MIN PAT CHANNEL ITER; returns 1 if not canonical.
parse() {
    [[ $1 =~ $RE ]] || return 1
    MAJ=${BASH_REMATCH[1]}
    MIN=${BASH_REMATCH[2]}
    PAT=${BASH_REMATCH[3]}
    CHANNEL=${BASH_REMATCH[5]:-stable}
    ITER=${BASH_REMATCH[6]:-}
}

rank() {
    case $1 in
        alpha) echo 0 ;;
        beta) echo 1 ;;
        rc) echo 2 ;;
        stable) echo 3 ;;
    esac
}

[ $# -ge 1 ] || die "usage: release-version.sh <tag> | --sort-key <tag> | --gh-release-flags <tag> <true|false> | --highest-stable | --check-build-env"

case $1 in
    --sort-key)
        [ $# -eq 2 ] || die "usage: --sort-key <tag>"
        parse "$2" || die "not a canonical release tag"
        printf '%09d.%09d.%09d.%d.%09d\n' "$MAJ" "$MIN" "$PAT" "$(rank "$CHANNEL")" "${ITER:-0}"
        ;;
    --gh-release-flags)
        [ $# -eq 3 ] || die "usage: --gh-release-flags <tag> <true|false>"
        parse "$2" || die "not a canonical release tag"
        case $3 in true | false) ;; *) die "highest-stable flag must be true or false" ;; esac
        if [ "$CHANNEL" = stable ]; then
            printf '%s\n' "--latest=$3"
        else
            printf '%s\n' "--prerelease --latest=false"
        fi
        ;;
    --highest-stable)
        [ $# -eq 1 ] || die "usage: --highest-stable  (tag names on stdin)"
        best=""
        best_key=""
        while IFS= read -r t || [ -n "$t" ]; do
            parse "$t" || continue
            [ "$CHANNEL" = stable ] || continue
            key="$(printf '%09d.%09d.%09d' "$MAJ" "$MIN" "$PAT")"
            if [ -z "$best" ] || [[ $key > $best_key ]]; then
                best="$t"
                best_key="$key"
            fi
        done
        [ -z "$best" ] || printf '%s\n' "$best"
        ;;
    --check-build-env)
        [ $# -eq 1 ] || die "usage: --check-build-env"
        version=${VERSION-}
        channel=${BUILD_CHANNEL-}
        tag=${RELEASE_TAG-}
        { parse "v$version" && [ "$CHANNEL" = stable ]; } || die "VERSION must be X.Y.Z (got '$version')"
        case $channel in
            release)
                [ -n "$tag" ] || die "release builds need RELEASE_TAG"
                parse "$tag" || die "RELEASE_TAG is not a canonical release tag (got '$tag')"
                [ "$MAJ.$MIN.$PAT" = "$version" ] || die "RELEASE_TAG $tag does not match VERSION $version"
                ;;
            source | dev)
                [ -z "$tag" ] || die "RELEASE_TAG must be empty for $channel builds"
                ;;
            *)
                die "BUILD_CHANNEL must be release, source or dev (got '$channel')"
                ;;
        esac
        ;;
    --*)
        die "unknown option $1"
        ;;
    *)
        [ $# -eq 1 ] || die "usage: release-version.sh <tag>"
        parse "$1" || die "not a canonical release tag"
        if [ "$CHANNEL" = stable ]; then prerelease=false; else prerelease=true; fi
        printf 'RELEASE_TAG=%s\n' "$1"
        printf 'VERSION=%s\n' "$MAJ.$MIN.$PAT"
        printf 'RELEASE_CHANNEL=%s\n' "$CHANNEL"
        printf 'RELEASE_ITERATION=%s\n' "$ITER"
        printf 'PRERELEASE=%s\n' "$prerelease"
        printf 'DISPLAY_VERSION=%s\n' "${1#v}"
        printf 'ASSET_NAME=%s\n' "AI-Pet-Usage-$1-arm64.zip"
        ;;
esac
