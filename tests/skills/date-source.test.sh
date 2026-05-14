#!/usr/bin/env bash
# WS-7 task 3: sweep skills/ and agents/ for any `date +%Y` that is not
# preceded by `-u`. The canonical date source rule (orchestrator-rules #14)
# requires UTC everywhere. Catches future regressions that copy a local-TZ
# `date +%Y-%m-%d` invocation back into a skill.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

# Search for `date +%Y` (in any quoting form) excluding the canonical `date -u +%Y`.
# Output: one line per offender as "<path>:<lineno>:<line>".
offenders=$(grep -rEn '(^|[^u])date \+(%Y|"%Y|'"'"'%Y)' "$REPO_ROOT/skills" "$REPO_ROOT/agents" 2>/dev/null || true)

if [ -z "$offenders" ]; then
    _pass 'no `date +%Y` without -u in skills/ or agents/'
else
    _fail 'date sweep' "found offenders (use `date -u +%Y…` instead):
$offenders"
fi

# Positive smoke: orchestrator-rules.md declares the canonical-date constraint.
if grep -qF "Canonical date source" "$REPO_ROOT/skills/dev-workflow/context/orchestrator-rules.md"; then
    _pass 'orchestrator-rules.md declares the canonical-date constraint'
else
    _fail 'canonical-date rule' 'orchestrator-rules.md missing the Canonical date source constraint'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0
