#!/usr/bin/env bash
# Doc-grep regression: agents/planner/index.md contains the FR-10 TDD-skip
# heuristics section with all four canonical category identifiers, and the
# category names match those declared in the quick-mode-config template
# (single source of truth per ADR-011, CC-04.1).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLANNER="$REPO_ROOT/agents/planner/index.md"
CONFIG_TEMPLATE="$REPO_ROOT/skills/init-workspace/templates/quick-mode-config.md"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s — %s\n' "$1" "$2" >&2; }

# ── Section existence ────────────────────────────────────────────────────────

_assert_section() {
    if grep -qF 'TDD-Skip Heuristics' "$PLANNER"; then
        _pass "planner/index.md has TDD-Skip Heuristics section"
    else
        _fail "TDD-Skip Heuristics section" "heading not found in planner/index.md"
    fi
}

# ── Canonical category identifiers present ───────────────────────────────────

_assert_category() {
    local cat="$1"
    if grep -qF "$cat" "$PLANNER"; then
        _pass "planner/index.md contains category '$cat'"
    else
        _fail "category '$cat'" "not found in planner/index.md"
    fi
}

# ── Category name parity with quick-mode-config template ────────────────────

_assert_config_parity() {
    local cat="$1"
    if grep -qF "$cat" "$CONFIG_TEMPLATE"; then
        _pass "quick-mode-config.md contains matching category '$cat'"
    else
        _fail "config parity '$cat'" \
            "category '$cat' in planner/index.md has no match in quick-mode-config template (ADR-011 violation)"
    fi
}

# ── Budget: file stays within agent-prompt hard cap (CC-04.8) ────────────────

_assert_budget() {
    local lines
    lines="$(wc -l < "$PLANNER")"
    if [ "$lines" -le 400 ]; then
        _pass "planner/index.md within 400-line agent-prompt hard cap ($lines lines)"
    else
        _fail "agent-prompt budget" \
            "planner/index.md is $lines lines — exceeds 400-line hard cap (CC-04.8)"
    fi
}

# ── ADR-011 back-reference ────────────────────────────────────────────────────

_assert_adr_ref() {
    if grep -qF 'ADR-011' "$PLANNER"; then
        _pass "planner/index.md references ADR-011 (shared source of truth)"
    else
        _fail "ADR-011 reference" "not found in planner/index.md — required by CC-04.1"
    fi
}

# ── Run all checks ────────────────────────────────────────────────────────────

_assert_section
_assert_category "ui-style-copy"
_assert_category "infra-config"
_assert_category "exploratory-data"
_assert_category "doc-only"
_assert_config_parity "ui-style-copy"
_assert_config_parity "infra-config"
_assert_config_parity "exploratory-data"
_assert_config_parity "doc-only"
_assert_budget
_assert_adr_ref

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for f in "${fail_msgs[@]}"; do printf '  - %s\n' "$f" >&2; done
    exit 1
fi
