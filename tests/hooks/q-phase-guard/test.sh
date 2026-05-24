#!/usr/bin/env bash
# Unit tests for scripts/q_phase_guard.py (IMPL-25-01).
#
# Validates CC-05.8 invariants I-1..I-3 and FR-1.4 hard-threshold enforcement:
#   1. LOC > 80 → entry denied (exit 2, "restart in full mode" message)
#   2. Security-sensitive path → entry denied regardless of LOC (I-3)
#   3. Small safe diff → entry allowed (exit 0)
#   4. Planner invocation → refused (I-1, exit 2)
#   5. Tester invocation → refused (I-1, exit 2)
#   6. Developer invocation → allowed (exit 0)
#   7. Reviewer invocation → allowed (exit 0)
#   8. Upgrade mid-flow → refused (I-2, exit 2)
#   9. Public-API path → entry denied regardless of LOC
#  10. Migration path → entry denied regardless of LOC
#
# CC conventions validated: CC-05.8 (I-1, I-2, I-3), FR-1.4, ADR-001, ADR-011.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

SCRIPT="$(repo_root)/scripts/q_phase_guard.py"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build a minimal unified diff.
# Args: n_files  lines_per_file  [file_path_prefix]
_make_diff() {
    local n_files="${1:-1}"
    local lines_per_file="${2:-1}"
    local prefix="${3:-src/widget}"
    local out=""
    local i
    for i in $(seq 1 "$n_files"); do
        out+="diff --git a/${prefix}${i}.py b/${prefix}${i}.py"$'\n'
        out+="--- a/${prefix}${i}.py"$'\n'
        out+="+++ b/${prefix}${i}.py"$'\n'
        out+="@@ -1,1 +1,${lines_per_file} @@"$'\n'
        local j
        for j in $(seq 1 "$lines_per_file"); do
            out+="-old_${j}"$'\n'
            out+="+new_${j}"$'\n'
        done
    done
    printf '%s' "$out"
}

# Write diff to a temp file and run guard --diff against it.
# Captures: _last_rc, _last_json
_check_entry() {
    local diff_text="$1"
    local tmp
    tmp="$(mktemp -t qpg_diff.XXXXXX)"
    printf '%s' "$diff_text" > "$tmp"
    _last_json="$(python3 "$SCRIPT" --diff "$tmp" 2>/dev/null)"
    _last_rc=$?
    rm -f "$tmp"
}

_allowed() { printf '%s' "$1" | python3 -c "import json,sys; print(json.load(sys.stdin)['allowed'])"; }
_reason()  { printf '%s' "$1" | python3 -c "import json,sys; print(json.load(sys.stdin)['reason'] or '')"; }

# ---------------------------------------------------------------------------
# Test 1: LOC > 80 → entry denied
# ---------------------------------------------------------------------------

test_entry_denied_when_loc_exceeds_80() {
    # 41 added + 41 removed per file = 82 loc_delta (> 80 limit)
    local diff
    diff="$(_make_diff 1 41)"
    _check_entry "$diff"
    [ "$_last_rc" -eq 2 ] || { _fail "expected exit 2 for LOC>80, got $_last_rc"; return; }
    local allowed
    allowed="$(_allowed "$_last_json")"
    [ "$allowed" = "False" ] || { _fail "expected allowed=False for LOC>80, got $allowed"; return; }
    _reason "$_last_json" | grep -qi "restart in full mode" || {
        _fail "abort message must mention 'restart in full mode'"
    }
}

# ---------------------------------------------------------------------------
# Test 2: Security path → entry denied regardless of LOC (I-3)
# ---------------------------------------------------------------------------

test_entry_denied_for_security_path_even_with_1_line() {
    # 1 line changed, but in auth/ (security-sensitive path)
    local diff
    diff="$(_make_diff 1 1 "auth/login")"
    _check_entry "$diff"
    [ "$_last_rc" -eq 2 ] || { _fail "expected exit 2 for security path, got $_last_rc"; return; }
    local reason
    reason="$(_reason "$_last_json")"
    printf '%s' "$reason" | grep -qi "security\|I-3" || {
        _fail "abort reason must mention security or I-3, got: $reason"
    }
}

# ---------------------------------------------------------------------------
# Test 3: Small safe diff → entry allowed
# ---------------------------------------------------------------------------

test_entry_allowed_for_small_safe_diff() {
    # 1 file, 1 line changed — well within all thresholds
    local diff
    diff="$(_make_diff 1 1)"
    _check_entry "$diff"
    [ "$_last_rc" -eq 0 ] || { _fail "expected exit 0 for safe diff, got $_last_rc"; return; }
    local allowed
    allowed="$(_allowed "$_last_json")"
    [ "$allowed" = "True" ] || { _fail "expected allowed=True for safe diff, got $allowed"; }
}

# ---------------------------------------------------------------------------
# Test 4: Planner → refused (I-1)
# ---------------------------------------------------------------------------

test_refuse_agent_blocks_planner() {
    local json
    json="$(python3 "$SCRIPT" --refuse-agent "ai-sdlc-planner" 2>/dev/null)"
    local rc=$?
    [ "$rc" -eq 2 ] || { _fail "expected exit 2 for planner, got $rc"; return; }
    printf '%s' "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['allowed'] == False, f'expected allowed=False, got {d}'
assert 'I-1' in (d.get('invariant') or ''), f'expected I-1 in invariant, got {d}'
" || _fail "planner refusal JSON malformed or missing I-1"
}

# ---------------------------------------------------------------------------
# Test 5: Tester → refused (I-1)
# ---------------------------------------------------------------------------

test_refuse_agent_blocks_tester() {
    local json
    json="$(python3 "$SCRIPT" --refuse-agent "ai-sdlc-tester" 2>/dev/null)"
    local rc=$?
    [ "$rc" -eq 2 ] || { _fail "expected exit 2 for tester, got $rc"; return; }
    printf '%s' "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['allowed'] == False, f'expected allowed=False'
" || _fail "tester refusal JSON malformed"
}

# ---------------------------------------------------------------------------
# Test 6: Developer → allowed
# ---------------------------------------------------------------------------

test_refuse_agent_allows_developer() {
    local json
    json="$(python3 "$SCRIPT" --refuse-agent "ai-sdlc-developer" 2>/dev/null)"
    local rc=$?
    [ "$rc" -eq 0 ] || { _fail "expected exit 0 for developer, got $rc"; return; }
    printf '%s' "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['allowed'] == True, f'developer must be allowed, got {d}'
" || _fail "developer allow JSON malformed"
}

# ---------------------------------------------------------------------------
# Test 7: Reviewer → allowed
# ---------------------------------------------------------------------------

test_refuse_agent_allows_reviewer() {
    local json
    json="$(python3 "$SCRIPT" --refuse-agent "ai-sdlc-reviewer" 2>/dev/null)"
    local rc=$?
    [ "$rc" -eq 0 ] || { _fail "expected exit 0 for reviewer, got $rc"; return; }
}

# ---------------------------------------------------------------------------
# Test 8: Upgrade mid-flow → refused (I-2)
# ---------------------------------------------------------------------------

test_refuse_upgrade_always_denied() {
    local json
    json="$(python3 "$SCRIPT" --refuse-upgrade 2>/dev/null)"
    local rc=$?
    [ "$rc" -eq 2 ] || { _fail "expected exit 2 for upgrade, got $rc"; return; }
    printf '%s' "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d['allowed'] == False, f'upgrade must be denied, got {d}'
assert 'I-2' in (d.get('invariant') or ''), f'expected I-2 in invariant, got {d}'
" || _fail "upgrade refusal JSON malformed or missing I-2"
}

# ---------------------------------------------------------------------------
# Test 9: Public-API path → denied regardless of LOC
# ---------------------------------------------------------------------------

test_entry_denied_for_public_api_path() {
    # 1 line, but touches api/__init__.py (public API pattern)
    local diff
    diff="$(_make_diff 1 1 "src/api/__init__")"
    # Override the file extension to match a public API pattern
    diff="${diff//__init__1.py/__init__.py}"
    _check_entry "$diff"
    [ "$_last_rc" -eq 2 ] || { _fail "expected exit 2 for public API path, got $_last_rc (diff: $diff)"; return; }
    _reason "$_last_json" | grep -qi "public" || {
        _fail "abort reason must mention public API, got: $(_reason "$_last_json")"
    }
}

# ---------------------------------------------------------------------------
# Test 10: Migration path → denied regardless of LOC
# ---------------------------------------------------------------------------

test_entry_denied_for_migration_path() {
    # 1 line, but in migrations/
    local diff
    diff="$(_make_diff 1 1 "db/migrations/0042_add_column")"
    _check_entry "$diff"
    [ "$_last_rc" -eq 2 ] || { _fail "expected exit 2 for migration path, got $_last_rc"; return; }
    _reason "$_last_json" | grep -qi "migrat" || {
        _fail "abort reason must mention migration, got: $(_reason "$_last_json")"
    }
}

run_all_tests
