#!/bin/bash
# Tests for the canonical release tooling (docs/release/VERSIONING.md):
#   Scripts/release-version.sh   — grammar, resolve output, sort keys, gh flags, highest stable, build-env invariants
#   Scripts/reconcile-latest.sh  — Latest reconciliation against a fake gh, including a concurrent stale write and
#                                  the 1000-release listing bound
#   Scripts/write-info-plist.sh  — Info.plist version identity (release vs source/dev)
#   .github/workflows/release-app.yml — canonical-only wiring guards (the workflow itself can't run locally); its
#                                  pre-publish Latest snapshot block runs verbatim against the fake gh
# Vectors: Sources/usagecore-tests/Fixtures/canonical-version-vectors.tsv (frozen, shared with usagecore-tests
# and the Homebrew tap). Run: /bin/bash Scripts/test-release-version.sh   (exit 0 = all pass)
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RV="$ROOT/Scripts/release-version.sh"
WP="$ROOT/Scripts/write-info-plist.sh"
VECTORS="$ROOT/Sources/usagecore-tests/Fixtures/canonical-version-vectors.tsv"
WF="$ROOT/.github/workflows/release-app.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }

# Split one TSV line on TABs, keeping empty fields (IFS=$'\t' read would merge consecutive tabs).
split_tsv() {
    local rest="$1"
    F=()
    while [[ $rest == *$'\t'* ]]; do
        F+=("${rest%%$'\t'*}")
        rest="${rest#*$'\t'}"
    done
    F+=("$rest")
}

# ---------------------------------------------------------------- 1. shared vectors
n_accept=0
n_reject=0
n_order=0
while IFS= read -r line || [ -n "$line" ]; do
    case $line in '' | '#'*) continue ;; esac
    split_tsv "$line"
    kind="${F[0]}"
    input="${F[1]-}"
    input="${input//\\n/$'\n'}"
    case $kind in
        accept)
            n_accept=$((n_accept + 1))
            iter="${F[4]}"
            [ "$iter" = "-" ] && iter=""
            want="RELEASE_TAG=$input
VERSION=${F[2]}
RELEASE_CHANNEL=${F[3]}
RELEASE_ITERATION=$iter
PRERELEASE=${F[5]}
DISPLAY_VERSION=${F[6]}
ASSET_NAME=${F[7]}"
            out="$("$RV" "$input" 2>"$TMP/err")"
            check "accept exit [$input]" "$?" 0
            check "accept output [$input]" "$out" "$want"
            key="$("$RV" --sort-key "$input")"
            check "sort-key exit [$input]" "$?" 0
            if [[ $key =~ ^[0-9]{9}\.[0-9]{9}\.[0-9]{9}\.[0-3]\.[0-9]{9}$ ]]; then ok; else bad "sort-key shape [$input]: $key"; fi
            ;;
        reject)
            n_reject=$((n_reject + 1))
            out="$("$RV" "$input" 2>"$TMP/err")"
            check "reject exit [$input] (${F[2]-})" "$?" 2
            check "reject stdout empty [$input]" "$out" ""
            if grep -q '^release-version: not a canonical release tag$' "$TMP/err"; then ok; else bad "reject message [$input]"; fi
            out="$("$RV" --sort-key "$input" 2>/dev/null)"
            check "reject sort-key exit [$input]" "$?" 2
            check "reject sort-key stdout empty [$input]" "$out" ""
            ;;
        order)
            n_order=$((n_order + 1))
            lo="$("$RV" --sort-key "$input")"
            hi="$("$RV" --sort-key "${F[2]}")"
            if [[ $lo < $hi ]]; then ok; else bad "order: $input must sort below ${F[2]} ($lo vs $hi)"; fi
            if [[ $hi > $lo ]]; then ok; else bad "order (reverse): ${F[2]} must sort above $input"; fi
            ;;
        *)
            bad "unknown vector kind [$kind]"
            ;;
    esac
done < "$VECTORS"
check "accept vector count" "$n_accept" 15
check "reject vector count" "$n_reject" 47
check "order vector count" "$n_order" 13

# ---------------------------------------------------------------- 2. gh release flags (D5)
flags() { "$RV" --gh-release-flags "$@" 2>/dev/null; }
check "flags alpha" "$(flags v0.1.0-alpha.3 false)" "--prerelease --latest=false"
check "flags beta (highest=true ignored)" "$(flags v0.1.0-beta.1 true)" "--prerelease --latest=false"
check "flags rc" "$(flags v0.1.0-rc.2 false)" "--prerelease --latest=false"
check "flags stable highest" "$(flags v0.1.0 true)" "--latest=true"
check "flags stable not highest" "$(flags v0.1.0 false)" "--latest=false"
flags v0.1.0 yes >/dev/null; check "flags bad highest arg exit" "$?" 2
flags alpha-v0.4.0 false >/dev/null; check "flags legacy tag exit" "$?" 2
flags v0.1.0 >/dev/null; check "flags missing arg exit" "$?" 2

# ---------------------------------------------------------------- 2b. highest canonical stable (Latest)
hs() { printf "$1" | "$RV" --highest-stable 2>/dev/null; }
check "highest-stable picks by canonical order" \
    "$(hs 'alpha-v9.9.9\nv0.1.0-beta.1\nv0.9.0\nv0.10.0\nv0.10.0-rc.1\nv1.0.0-alpha.1\nV2.0.0\nv01.0.0\n')" "v0.10.0"
check "highest-stable is order-independent" "$(hs 'v0.10.0\nv0.9.0\nv0.1.0-beta.1\n')" "v0.10.0"
check "highest-stable hotfix does not outrank a newer line" "$(hs 'v1.1.0\nv1.0.9\n')" "v1.1.0"
check "highest-stable empty input" "$(hs '')" ""
hs '' >/dev/null; check "highest-stable empty input exit" "$?" 0
check "highest-stable ignores prereleases, legacy and malformed" "$(hs 'v0.2.0-rc.1\nalpha-v0.4.0\nv0.3.0-beta.1\nv1.0\n')" ""
check "highest-stable reads a last line without newline" "$(hs 'v0.1.0\nv0.2.0')" "v0.2.0"
check "highest-stable ignores a CRLF line" "$(hs 'v9.9.9\r\nv0.1.0\n')" "v0.1.0"
"$RV" --highest-stable extra < /dev/null >/dev/null 2>&1; check "highest-stable rejects arguments" "$?" 2
best_tag=""
best_key=""
while IFS= read -r line || [ -n "$line" ]; do
    case $line in accept*) ;; *) continue ;; esac
    split_tsv "$line"
    [ "${F[3]}" = stable ] || continue
    k="$("$RV" --sort-key "${F[1]}")"
    if [ -z "$best_tag" ] || [[ $k > $best_key ]]; then best_tag="${F[1]}"; best_key="$k"; fi
    printf '%s\n' "${F[1]}"
done < "$VECTORS" > "$TMP/stable-vectors.txt"
check "stable accept vectors exist" "$([ -n "$best_tag" ] && echo yes)" "yes"
check "highest-stable over every stable accept vector (reversed) == max sort key" \
    "$(sed '1!G;h;$!d' "$TMP/stable-vectors.txt" | "$RV" --highest-stable)" "$best_tag"

# ---------------------------------------------------------------- 2c. Latest reconciliation (fake gh)
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKEGH'
#!/bin/bash
# Fake gh. State in $FAKE_GH_DIR: stables (published stable tags, newest created first = gh's default order),
# latest (the Latest tag), calls.log. `release list` honors --limit N like gh (the first N; default 30).
# race_tag: on the first edit, a concurrent run first publishes that higher stable and crowns it, then our write lands.
D="$FAKE_GH_DIR"
printf '%s\n' "$*" >> "$D/calls.log"
case "$1 $2" in
    "release list")
        [ -e "$D/fail_list" ] && exit 1
        limit=30
        prev=""
        for a in "$@"; do
            [ "$prev" = "--limit" ] && limit="$a"
            prev="$a"
        done
        head -n "$limit" "$D/stables" ;;
    "release edit")
        [ -e "$D/fail_edit" ] && exit 1
        if [ -e "$D/race_tag" ]; then
            cat "$D/race_tag" >> "$D/stables"
            cp "$D/race_tag" "$D/latest"
            rm "$D/race_tag"
        fi
        printf '%s\n' "$3" > "$D/latest" ;;
    api*) cat "$D/latest" 2>/dev/null ;;
    *) exit 3 ;;
esac
FAKEGH
chmod +x "$TMP/bin/gh"
n_fake=0
reconcile() { # <tag> <stables, newline-separated> <latest> [race_tag] [fail_list|fail_edit] -> rc, final, edits, calls
    n_fake=$((n_fake + 1))
    local d="$TMP/gh.$n_fake"
    mkdir -p "$d"
    printf '%s' "$2" > "$d/stables"
    printf '%s' "$3" > "$d/latest"
    : > "$d/calls.log"
    if [ -n "${4-}" ]; then printf '%s\n' "$4" > "$d/race_tag"; fi
    if [ -n "${5-}" ]; then : > "$d/$5"; fi
    FAKE_GH_DIR="$d" PATH="$TMP/bin:$PATH" RECONCILE_ATTEMPTS=3 RECONCILE_SETTLE_S=0 RECONCILE_RETRY_S=0 \
        "$ROOT/Scripts/reconcile-latest.sh" F-e-u-e-r/ai-pet-usage "$1" >/dev/null 2>&1
    rc=$?
    final="$(cat "$d/latest")"
    edits="$(grep -c '^release edit' "$d/calls.log")"
    calls="$(wc -l < "$d/calls.log" | tr -d ' ')"
}
reconcile v1.0.0 $'v0.9.0\n' v0.9.0
check "reconcile: new highest stable becomes Latest" "$rc|$final|$edits" "0|v1.0.0|1"
reconcile v1.0.1 $'v1.1.0\n' v1.1.0
check "reconcile: an older-line hotfix leaves the higher stable Latest" "$rc|$final|$edits" "0|v1.1.0|0"
reconcile v0.1.0 '' ''
check "reconcile: first stable ever" "$rc|$final" "0|v0.1.0"
reconcile v1.0.0 '' '' v1.1.0
check "reconcile: a concurrent higher publish that lands before our stale write is restored" "$rc|$final|$edits" "0|v1.1.0|2"
reconcile v1.0.0 $'alpha-v0.4.0\nv2.0.0-rc.1\nV3.0.0\nv01.0.0\nv0.9.0\n' v0.9.0
check "reconcile: legacy, prerelease and malformed tags are ignored" "$rc|$final" "0|v1.0.0"
reconcile v1.0.0 $'v0.9.0\n' v0.9.0 '' fail_edit
check "reconcile: an edit that never takes effect fails the run" "$rc|$final" "1|v0.9.0"
reconcile v1.0.0 $'v0.9.0\n' v0.9.0 '' fail_list
check "reconcile: a failed listing aborts without editing" "$rc|$edits" "2|0"
reconcile v1.0.0-rc.1 $'v0.9.0\n' v0.9.0
check "reconcile: a non-stable tag is refused before any gh call" "$rc|$calls" "2|0"
# Bounded listing (1000 releases; one more is requested). The newest 1000 stables hide the semantic maximum v3.0.0
# (the oldest created): a listing over the bound is KNOWN to be incomplete and is refused like a failed listing.
over="$(printf 'v2.0.0\n'; seq 999 -1 1 | sed 's/^/v1.0./'; printf 'v3.0.0\n')"$'\n'    # 1001 stables, newest first
exact="$(printf 'v2.0.0\n'; seq 998 -1 1 | sed 's/^/v1.0./'; printf 'v3.0.0\n')"$'\n'   # exactly 1000
reconcile v2.0.0 "$over" v3.0.0
check "reconcile: a listing over the 1000-release bound aborts without editing" "$rc|$final|$edits" "2|v3.0.0|0"
check "reconcile: every stable listing asks for one more than the bound" \
    "$(grep -c '^release list' "$TMP/gh.$n_fake/calls.log")|$(grep -c -- '^release list .* --limit 1001 ' "$TMP/gh.$n_fake/calls.log")" "1|1"
reconcile v2.0.0 "$exact" v3.0.0
check "reconcile: exactly 1000 stables is a complete listing (the older v3.0.0 stays Latest)" "$rc|$final|$edits" "0|v3.0.0|0"

# ---------------------------------------------------------------- 2d. the workflow's pre-publish Latest snapshot
# The workflow cannot run locally, but its stable listing + HIGHEST_STABLE decision can: the block from
# `stable_tags() {` through the `fi` that closes it is extracted verbatim and run with the step's `set -euo pipefail`
# against the fake gh, from the repo root (it calls Scripts/release-version.sh).
wf_block="$(awk '/^          stable_tags\(\) \{$/ { on = 1 } on { print } on && /^          fi$/ { exit }' "$WF")"
check "workflow snapshot block found" "$(printf '%s\n' "$wf_block" | grep -c 'HIGHEST_STABLE=true')" 1
snapshot() { # <tag> <stables, newline-separated> -> rc, hs (HIGHEST_STABLE; empty if the block failed), out
    n_fake=$((n_fake + 1))
    local d="$TMP/gh.$n_fake"
    mkdir -p "$d"
    printf '%s' "$2" > "$d/stables"
    : > "$d/calls.log"
    out="$(cd "$ROOT" && FAKE_GH_DIR="$d" PATH="$TMP/bin:$PATH" RUNNER_TEMP="$d" RELEASE_CHANNEL=stable \
        RELEASE_TAG="$1" GITHUB_REPOSITORY=F-e-u-e-r/ai-pet-usage \
        bash -c 'set -euo pipefail; eval "$1"; printf "\nHIGHEST_STABLE=%s\n" "$HIGHEST_STABLE"' _ "$wf_block" 2>&1)"
    rc=$?
    hs="$(printf '%s\n' "$out" | sed -n 's/^HIGHEST_STABLE=//p')"
}
snapshot v1.0.0 $'v0.9.0\n'
check "workflow snapshot: a new highest stable is marked Latest" "$rc|$hs" "0|true"
snapshot v1.0.1 $'v1.1.0\n'
check "workflow snapshot: an older-line hotfix is not marked Latest" "$rc|$hs" "0|false"
# Before publishing, the tag being published is not listed yet: 1001 / 1000 earlier stables, the oldest v3.0.0.
over_pre="$(seq 1000 -1 1 | sed 's/^/v1.0./'; printf 'v3.0.0\n')"$'\n'
exact_pre="$(seq 999 -1 1 | sed 's/^/v1.0./'; printf 'v3.0.0\n')"$'\n'
snapshot v2.0.0 "$over_pre"
check "workflow snapshot: a listing over the 1000-release bound fails before publishing" \
    "$([ "$rc" -ne 0 ] && echo failed)|$hs|$(printf '%s\n' "$out" | grep -c 'more than 1000 stable releases')" "failed||1"
snapshot v2.0.0 "$exact_pre"
check "workflow snapshot: exactly 1000 stables is complete (the older v3.0.0 stays highest)" "$rc|$hs" "0|false"

# ---------------------------------------------------------------- 3. build-env invariants (B1–B5)
benv() { # <VERSION> <BUILD_CHANNEL> <RELEASE_TAG> -> exit status; stderr in $TMP/benv.err
    VERSION="$1" BUILD_CHANNEL="$2" RELEASE_TAG="$3" "$RV" --check-build-env >"$TMP/benv.out" 2>"$TMP/benv.err"
}
expect_benv_reject() { # <label> <message> <VERSION> <BUILD_CHANNEL> <RELEASE_TAG>
    benv "$3" "$4" "$5"
    check "$1 exit" "$?" 2
    if grep -qF "$2" "$TMP/benv.err"; then ok; else bad "$1 message: $(cat "$TMP/benv.err")"; fi
    check "$1 stdout empty" "$(cat "$TMP/benv.out")" ""
}
benv 0.1.0 release v0.1.0-beta.1; check "B1 release + canonical tag" "$?" 0
benv 0.1.0 release v0.1.0; check "B1 release + stable tag" "$?" 0
benv 0.0.0 source ""; check "source build without tag" "$?" 0
benv 0.0.0 dev ""; check "dev build without tag" "$?" 0
benv 0.4.0 source ""; check "source build with numeric VERSION" "$?" 0
expect_benv_reject "B2 release without tag" "release builds need RELEASE_TAG" 0.1.0 release ""
expect_benv_reject "B3 tag core != VERSION" "does not match VERSION" 0.1.1 release v0.1.0-beta.1
expect_benv_reject "B3 legacy release tag" "RELEASE_TAG is not a canonical release tag" 0.4.0 release alpha-v0.4.0
expect_benv_reject "B4 source build with tag" "RELEASE_TAG must be empty for source builds" 0.1.0 source v0.1.0-beta.1
expect_benv_reject "B4 dev build with tag" "RELEASE_TAG must be empty for dev builds" 0.1.0 dev v0.1.0-beta.1
expect_benv_reject "B5 prerelease VERSION" "VERSION must be X.Y.Z" 0.1.0-beta.1 release v0.1.0-beta.1
expect_benv_reject "B5 v-prefixed VERSION" "VERSION must be X.Y.Z" v0.1.0 source ""
expect_benv_reject "B5 leading-zero VERSION" "VERSION must be X.Y.Z" 01.0.0 source ""
expect_benv_reject "B5 empty VERSION" "VERSION must be X.Y.Z" "" source ""
expect_benv_reject "unknown build channel" "BUILD_CHANNEL must be release, source or dev" 0.1.0 beta ""

# ---------------------------------------------------------------- 4. write-info-plist.sh
plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }
VERSION=0.1.0 BUILD_CHANNEL=release RELEASE_TAG=v0.1.0-beta.1 "$WP" "$TMP/rel.plist" 2>"$TMP/wp.err"
check "plist release write exit" "$?" 0
if plutil -lint "$TMP/rel.plist" >/dev/null 2>&1; then ok; else bad "plist release lint"; fi
check "plist release short" "$(plist_get "$TMP/rel.plist" CFBundleShortVersionString)" "0.1.0"
check "plist release bundle version" "$(plist_get "$TMP/rel.plist" CFBundleVersion)" "0.1.0"
check "plist release build channel" "$(plist_get "$TMP/rel.plist" AIPetUsageBuildChannel)" "release"
check "plist release tag" "$(plist_get "$TMP/rel.plist" AIPetUsageReleaseTag)" "v0.1.0-beta.1"
VERSION=0.4.0 BUILD_CHANNEL=source "$WP" "$TMP/src.plist" 2>"$TMP/wp.err"
check "plist source write exit" "$?" 0
if plist_get "$TMP/src.plist" AIPetUsageReleaseTag >/dev/null; then bad "plist source must not carry AIPetUsageReleaseTag"; else ok; fi
# Representation pin: Info.plist is a contract (macOS + updater). Source builds stay byte-identical to the
# pre-reset build-app.sh heredoc; release builds add exactly one AIPetUsageReleaseTag line.
cat > "$TMP/src.expected" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AI Pet Usage</string>
    <key>CFBundleDisplayName</key><string>AI Pet Usage</string>
    <key>CFBundleIdentifier</key><string>dev.aipetusage.app</string>
    <key>CFBundleExecutable</key><string>AIPetUsage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.4.0</string>
    <key>CFBundleVersion</key><string>0.4.0</string>
    <key>AIPetUsageBuildChannel</key><string>source</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Local-first. Your usage data never leaves this Mac.</string>
</dict>
</plist>
EOF
if cmp -s "$TMP/src.plist" "$TMP/src.expected"; then ok; else bad "plist source bytes changed"; fi
check "plist release adds exactly one line" "$(diff "$TMP/src.expected" "$TMP/rel.plist" | grep -c '^> .*AIPetUsageReleaseTag')" 1
for bad_env in "0.1.0|release|" "0.1.1|release|v0.1.0-beta.1" "0.1.0|source|v0.1.0-beta.1" "0.1.0-beta.1|release|v0.1.0-beta.1"; do
    IFS='|' read -r v c t <<< "$bad_env"
    rm -f "$TMP/bad.plist"
    VERSION="$v" BUILD_CHANNEL="$c" RELEASE_TAG="$t" "$WP" "$TMP/bad.plist" 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then ok; else bad "write-info-plist accepted invalid env [$bad_env]"; fi
    if [ -e "$TMP/bad.plist" ]; then bad "write-info-plist wrote a plist for invalid env [$bad_env]"; else ok; fi
done

# ---------------------------------------------------------------- 5. release-app.yml wiring guards
triggers="$(awk '/^    tags:$/ {grab = 1; next} grab && /^      - / {print; next} grab {exit}' "$WF")"
check "workflow tag triggers are exactly the canonical patterns" "$triggers" "      - 'v[0-9]+.[0-9]+.[0-9]+'
      - 'v[0-9]+.[0-9]+.[0-9]+-alpha.[0-9]+'
      - 'v[0-9]+.[0-9]+.[0-9]+-beta.[0-9]+'
      - 'v[0-9]+.[0-9]+.[0-9]+-rc.[0-9]+'"
check "workflow has no literal --prerelease (flags come from release-version.sh)" "$(grep -cF -- '--prerelease' "$WF")" 0
check "workflow derives gh flags via release-version.sh" "$(grep -cF 'Scripts/release-version.sh --gh-release-flags' "$WF")" 1
check "workflow resolves the tag with release-version.sh" "$(grep -cF 'RESOLVED="$(Scripts/release-version.sh "${TAG}")"' "$WF")" 1
check "publish step only on canonical tag pushes" \
    "$(grep -cF "if: github.event_name == 'push' && github.ref_type == 'tag' && env.MODE == 'release'" "$WF")" 1
check "only one gh release create" "$(grep -cF 'gh release create' "$WF")" 1
check "dispatch input only reaches scripts via env" "$(grep -cF 'github.event.inputs' "$WF")" 1
check "dispatch input mapped to REHEARSE_TAG env" "$(grep -cF 'REHEARSE_TAG: ${{ github.event.inputs.rehearse_tag }}' "$WF")" 1
check "no legacy alpha-v prefix stripping" "$(grep -cF '#alpha-v' "$WF")" 0
check "workflow pre-estimates the highest stable via release-version.sh" \
    "$(grep -cF 'Scripts/release-version.sh --highest-stable' "$WF")" 1
check "workflow reconciles Latest via reconcile-latest.sh" \
    "$(grep -cF 'Scripts/reconcile-latest.sh "${GITHUB_REPOSITORY}" "${RELEASE_TAG}"' "$WF")" 1
check "workflow never edits Latest directly" "$(grep -cF 'gh release edit' "$WF")" 0
create_line="$(grep -n 'gh release create' "$WF" | cut -d: -f1)"
reconcile_line="$(grep -nF 'Scripts/reconcile-latest.sh "${GITHUB_REPOSITORY}" "${RELEASE_TAG}"' "$WF" | cut -d: -f1)"
if [ -n "$create_line" ] && [ -n "$reconcile_line" ] && [ "$create_line" -lt "$reconcile_line" ]; then ok; else bad "Latest reconciliation must follow gh release create"; fi
check "rehearsal refuses an existing tag that points elsewhere" "$(grep -cF 'already exists and points at' "$WF")" 1
check "rehearsal tag check compares the remote tag commit with the run's commit" \
    "$(grep -cF 'if [[ -n "${REMOTE_COMMIT}" && "${REMOTE_COMMIT}" != "${GITHUB_SHA}" ]]; then' "$WF")" 1
check "rehearsal tag mismatch exits non-zero" \
    "$(awk '/already exists and points at/ { getline; gsub(/^ +| +$/, ""); print; exit }' "$WF")" "exit 1"
strict_line="$(grep -n 'RESOLVED="$(Scripts/release-version.sh "${TAG}")"' "$WF" | cut -d: -f1)"
lsremote_line="$(grep -n 'git ls-remote --tags origin "refs/tags/${TAG}"' "$WF" | cut -d: -f1)"
if [ -n "$strict_line" ] && [ -n "$lsremote_line" ] && [ "$strict_line" -lt "$lsremote_line" ]; then ok; else bad "the rehearsal tag check must run after the strict resolve"; fi
resolve_line="$(grep -n 'name: Resolve canonical release version' "$WF" | cut -d: -f1)"
build_line="$(grep -n 'name: Build app bundle' "$WF" | cut -d: -f1)"
if [ -n "$resolve_line" ] && [ -n "$build_line" ] && [ "$resolve_line" -lt "$build_line" ]; then ok; else bad "resolve step must precede the build step"; fi
if command -v ruby >/dev/null 2>&1; then
    for y in "$WF" "$ROOT/.github/workflows/swift-tests.yml"; do
        if ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$y" >/dev/null 2>&1; then ok; else bad "YAML does not parse: ${y#"$ROOT"/}"; fi
    done
else
    printf 'SKIP: ruby not available — YAML parse checks not run\n'
fi

# ---------------------------------------------------------------- summary
total=$((pass + fail))
if [ "$fail" -eq 0 ] && [ "$total" -gt 0 ]; then
    printf 'release-version tests: PASS (%d checks; vectors %d accept / %d reject / %d order)\n' "$total" "$n_accept" "$n_reject" "$n_order"
    exit 0
fi
printf 'release-version tests: FAIL (%d of %d checks failed)\n' "$fail" "$total"
exit 1
