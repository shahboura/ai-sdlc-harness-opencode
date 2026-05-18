#!/usr/bin/env bash
# C6 regression: the Workflow Metric formerly known as `Development completed`
# is renamed to `Initial development completed` everywhere — the original
# stayed at the first Phase 3 close and never updated for Phase 7 amendments
# or ad-hoc batches that re-entered Phase 3, so the unqualified name was
# misleading. `Development started` keeps its name (the original start date
# is the relevant one regardless of later re-entries).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

# Files that must use the new name. (CHANGELOG.md historical entries are
# allowed to keep the old name — they record what was true at the time.)
FILES_NEW=(
    "$REPO_ROOT/skills/plan-generator/tracker-schema.md"
    "$REPO_ROOT/skills/plan-generator/SKILL.md"
    "$REPO_ROOT/skills/dev-workflow/context/orchestrator-rules.md"
    "$REPO_ROOT/skills/dev-workflow/commands/approve-impl.md"
    "$REPO_ROOT/README.md"
)

for f in "${FILES_NEW[@]}"; do
    name="$(basename "$f")"
    if grep -qF -- 'Initial development completed' "$f"; then
        _pass "$name uses the new \`Initial development completed\` name"
    else
        _fail "$name uses the new \`Initial development completed\` name" \
            'not found — the rename did not land in this file'
    fi
done

# The pre-C6 unqualified name must not appear as a live metric anywhere
# (CHANGELOG is the only place it's allowed, for historical accuracy).
for f in "${FILES_NEW[@]}"; do
    name="$(basename "$f")"
    # Match `Development completed` only when it's NOT preceded by `Initial `.
    # Some files mention the rename history alongside the new name; the
    # `Initial development completed` phrase itself contains the old substring
    # so we have to grep for the standalone occurrence.
    if grep -E -- '(^|[^l] )Development completed' "$f" | grep -vE 'Initial development completed' > /dev/null; then
        _fail "$name drops the legacy \`Development completed\` name" \
            'pre-C6 unqualified `Development completed` still appears as a live metric'
    else
        _pass "$name drops the legacy \`Development completed\` name"
    fi
done

# tracker-schema.md must explain WHY only `completed` got the rename and
# `started` did not.
SCHEMA="$REPO_ROOT/skills/plan-generator/tracker-schema.md"
if grep -qF -- 'started" half intentionally keeps the unqualified name' "$SCHEMA"; then
    _pass 'tracker-schema explains why `started` was NOT renamed'
else
    _fail 'tracker-schema explains why `started` was NOT renamed' \
        'expected the rationale line on the Development started row'
fi
if grep -qF -- 'PR review response completed' "$SCHEMA" && grep -qF -- 'Ad-hoc requests completed' "$SCHEMA"; then
    _pass 'tracker-schema points at the existing per-re-entry metrics'
else
    _fail 'tracker-schema points at the existing per-re-entry metrics' \
        'expected references to PR review response completed and Ad-hoc requests completed'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0
