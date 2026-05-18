#!/usr/bin/env bash
# C5 regression: the `<type>` placeholder in branch names is gone. Pre-C5,
# branch naming was documented as `<team>/<type>/<id>-<slug>` in CLAUDE.md
# and `<team-name>/<type>/<workitem-id>-<title>` in README / reviewer /
# create-pr / review-response / handle-request — but `<type>` was never wired
# to anything; every code path hard-coded `feature`. The placeholder
# misleadingly implied a configurable that didn't exist.
#
# Post-C5, every doc references the literal `feature` segment.
#
# Post-v2.0: the README no longer needs to explain WHY `<type>` was removed —
# that historical explanation has aged out of the doc rewrite. The check
# now asserts `<type>` is completely absent from the README (in addition
# to all live-convention files).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

# Files where the old placeholder must not appear as a live convention.
# (Excluded: tests/, .git/, CHANGELOG.md — historical record.)
FILES=(
    "$REPO_ROOT/CLAUDE.md"
    "$REPO_ROOT/agents/reviewer/index.md"
    "$REPO_ROOT/skills/dev-workflow/commands/handle-request.md"
    "$REPO_ROOT/skills/dev-workflow/commands/create-pr.md"
    "$REPO_ROOT/skills/dev-workflow/commands/review-response.md"
    "$REPO_ROOT/skills/dev-workflow/commands/preflight.md"
)

for f in "${FILES[@]}"; do
    name="$(basename "$f")"
    if grep -qF -- '<type>' "$f"; then
        _fail "$name drops <type> placeholder" \
            'still contains <type> in a live branch-naming snippet'
    else
        _pass "$name drops <type> placeholder"
    fi
done

# Post-v2.0: the README no longer carries the `<type>` explanation paragraph.
README_HITS=$(grep -cF -- '<type>' "$REPO_ROOT/README.md" 2>/dev/null || true)
if [ "$README_HITS" = "0" ]; then
    _pass 'README drops <type> placeholder (v2.0 rewrite)'
else
    _fail 'README drops <type> placeholder' \
        "README has $README_HITS occurrence(s) of <type> — the v2.0 rewrite should reference 'feature' literally"
fi

# The canonical branch convention is `<team-name>/feature/...` — assert each
# file documents it explicitly.
assert_canonical() {
    local f="$1" label="$2"
    if grep -qE -- '<team-name>/feature/|<team>/feature/' "$f"; then
        _pass "$label documents the canonical feature/ branch convention"
    else
        _fail "$label documents the canonical feature/ branch convention" \
            'no <team[-name]>/feature/... snippet found'
    fi
}
assert_canonical "$REPO_ROOT/CLAUDE.md" 'CLAUDE.md'
assert_canonical "$REPO_ROOT/README.md" 'README.md'
assert_canonical "$REPO_ROOT/agents/reviewer/index.md" 'reviewer/index.md'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0
