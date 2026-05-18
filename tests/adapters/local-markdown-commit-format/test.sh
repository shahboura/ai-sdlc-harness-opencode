#!/usr/bin/env bash
# A1 regression: every commit subject documented in the local-markdown
# adapter's ID Format table must be accepted by the validate-commit-msg
# hook. Catches the prior contradiction where the adapter prescribed
# `auth-story #T1: …` (no leading `#`) but the validator required one,
# making the entire local-markdown path unusable end-to-end.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ADAPTER="$REPO_ROOT/skills/providers/local-markdown/work-items.md"
SCRIPTS="$REPO_ROOT/scripts"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

# Run the validator against a synthetic `git commit -m <subject>` command.
# Exits 0 = accepted, 2 = blocked.
_run_validator() {
    local subject="$1"
    local cmd="git commit -m \"$subject\""
    PYTHONPATH="$SCRIPTS" python3 "$SCRIPTS/_validate_commit_msg.py" "$cmd" 2>/dev/null
}

_assert_accepted() {
    local subject="$1"
    local label="$2"
    if _run_validator "$subject"; then
        _pass "$label"
    else
        _fail "$label" "validator rejected subject: $subject"
    fi
}

# --- 0. Adapter file documents the `#` prefix ------------------------------
if grep -qF '`#auth-story #T1 test:' "$ADAPTER" \
   && grep -qF '`#auth-story #T1 impl:' "$ADAPTER" \
   && grep -qF '`#auth-story test-harden:' "$ADAPTER"; then
    _pass 'adapter documents `#` prefix on commit subjects'
else
    _fail 'adapter documents `#` prefix' \
        'expected to find the `#<filename> #T<n> test:`, `impl:`, and `test-harden:` forms in the adapter file'
fi

# --- 1. Adapter no longer documents the pre-A1 unprefixed form ------------
if grep -qE '^\- \*\*In commit messages\*\*: `auth-story #T1: description`' "$ADAPTER"; then
    _fail 'adapter drops unprefixed legacy example' \
        'pre-A1 example `auth-story #T1: description` (no leading #) still present — validator would reject it'
else
    _pass 'adapter drops unprefixed legacy example'
fi

# --- 2. Every documented subject form passes the validator ----------------
# These mirror the rows in the adapter's ID Format table.
_assert_accepted '#auth-story #T1 test: add token refresh contract test' \
    'Phase 3 tester TDD form accepted'
_assert_accepted '#auth-story #T1 impl: add token refresh endpoint' \
    'Phase 3 developer TDD form accepted'
_assert_accepted '#auth-story #T1: rename helper module' \
    'Phase 3 non-TDD form accepted'
_assert_accepted '#auth-story test-harden: add integration tests for token refresh' \
    'Phase 5 hardening form accepted'
_assert_accepted '#auth-story #TPLAN: add approved implementation plan' \
    'Phase 6 plan commit accepted'
_assert_accepted '#auth-story #TTRACKER: add task tracker with final workflow state' \
    'Phase 6 tracker commit accepted'
_assert_accepted '#auth-story #TPR-RESP: record PR review response completion' \
    'Phase 7 tracker update accepted'

# --- 3. Filenames with dots and underscores (legal in story-ID slot) ------
_assert_accepted '#auth.feature #T1 test: cover happy path' \
    'dotted filename accepted'
_assert_accepted '#auth_story #T1 impl: wire up handler' \
    'underscored filename accepted'

# --- 4. Negative — the legacy unprefixed form is still rejected by the
# validator (regression catch — if the validator ever loosens, this fails).
if _run_validator 'auth-story #T1: description'; then
    _fail 'legacy unprefixed form rejected by validator' \
        'validator accepted `auth-story #T1: description` — story-ID regex has been loosened'
else
    _pass 'legacy unprefixed form rejected by validator'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0
