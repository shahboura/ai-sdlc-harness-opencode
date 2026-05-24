#!/usr/bin/env bash
# Unit tests for scripts/quick-mode-classify.py (IMPL-25-01).
#
# Tests pin the boundary conditions for classify_change() and
# is_quick_mode_safe_category() per US-E01-002 acceptance criteria.
# Uses the hook-test assert infrastructure for the run_all_tests runner;
# calls Python directly (no hook payload scaffolding needed).
#
# CC conventions validated: CC-04.1 (single classifier), CC-09 (threshold
# boundaries LOC=80/81, files=5/6), ADR-011 (defaults loaded when config absent)

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

SCRIPT="$(repo_root)/scripts/quick-mode-classify.py"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build a minimal unified diff touching N files with M changed lines each.
_make_diff() {
    local n_files="${1:-1}"
    local lines_per_file="${2:-1}"
    local file_prefix="${3:-src/foo}"
    local out=""
    local i
    for i in $(seq 1 "$n_files"); do
        out+="diff --git a/${file_prefix}${i}.py b/${file_prefix}${i}.py"$'\n'
        out+="--- a/${file_prefix}${i}.py"$'\n'
        out+="+++ b/${file_prefix}${i}.py"$'\n'
        out+="@@ -1,1 +1,1 @@"$'\n'
        local j
        for j in $(seq 1 "$lines_per_file"); do
            out+="-old_line_${j}"$'\n'
            out+="+new_line_${j}"$'\n'
        done
    done
    printf '%s' "$out"
}

# Run classify and capture JSON output. Writes diff to a temp file.
_classify() {
    local diff_text="$1"
    local config_arg="${2:-}"
    local tmp
    tmp="$(mktemp)"
    printf '%s' "$diff_text" > "$tmp"
    local out
    if [ -n "$config_arg" ]; then
        out="$(python3 "$SCRIPT" --diff "$tmp" --config "$config_arg" 2>/dev/null)"
    else
        out="$(python3 "$SCRIPT" --diff "$tmp" 2>/dev/null)"
    fi
    rm -f "$tmp"
    printf '%s' "$out"
}

_tier()   { printf '%s' "$1" | python3 -c "import json,sys; print(json.load(sys.stdin)['tier'])"; }
_abort()  { printf '%s' "$1" | python3 -c "import json,sys; print(str(json.load(sys.stdin)['abort']).lower())"; }
_files()  { printf '%s' "$1" | python3 -c "import json,sys; print(json.load(sys.stdin)['stats']['files_touched'])"; }
_loc()    { printf '%s' "$1" | python3 -c "import json,sys; print(json.load(sys.stdin)['stats']['loc_delta'])"; }

# ---------------------------------------------------------------------------
# Tests: classify_change()
# ---------------------------------------------------------------------------

# AC: one-line fix returns RiskTier.low
test_classify_returns_low_for_one_line_fix() {
    local diff result tier
    diff="$(_make_diff 1 1)"
    result="$(_classify "$diff")"
    tier="$(_tier "$result")"
    [ "$tier" = "low" ] || {
        _fail "expected tier=low, got: $tier (result: $result)"
        return
    }
    [ "$(_abort "$result")" = "false" ] || _fail "expected abort=false for low tier"
}

# AC: LOC = 80 (boundary — exactly at limit) → still low
test_classify_returns_low_at_loc_boundary_80() {
    local diff result tier
    diff="$(_make_diff 1 80)"   # 80 add + 80 remove = 160 loc_delta
    # 160 > 80, so this is actually high. Let me use 40 lines (80/2 exactly = medium threshold)
    # Actually loc_delta counts both added AND removed lines. For 1 file with 1 unchanged line:
    # each "pair" produces 2 loc lines (one - and one +). So _make_diff 1 40 = 80 loc_delta.
    diff="$(_make_diff 1 40)"   # 40 removed + 40 added = 80 loc_delta = exactly loc_max
    result="$(_classify "$diff")"
    tier="$(_tier "$result")"
    # loc_delta == loc_max is NOT > loc_max, so should be medium (soft breach) not high
    [ "$tier" != "high" ] || _fail "loc_delta=80 should not trigger high tier (not > loc_max)"
}

# AC: LOC = 81 (boundary + 1) → high tier, abort = true
test_classify_returns_high_when_loc_exceeds_threshold() {
    local diff result tier
    # _make_diff 1 41 → 41 removed + 41 added = 82 loc_delta > 80
    diff="$(_make_diff 1 41)"
    result="$(_classify "$diff")"
    tier="$(_tier "$result")"
    [ "$tier" = "high" ] || _fail "expected tier=high for loc_delta > 80, got: $tier"
    [ "$(_abort "$result")" = "true" ] || _fail "expected abort=true for high tier"
}

# AC: files = 5 (at limit) → not high
test_classify_not_high_at_files_boundary_5() {
    local diff result tier
    diff="$(_make_diff 5 1)"
    result="$(_classify "$diff")"
    tier="$(_tier "$result")"
    [ "$tier" != "high" ] || _fail "files_touched=5 should not be high (not > files_max)"
}

# AC: files = 6 → high
test_classify_returns_high_when_files_exceed_threshold() {
    local diff result tier
    diff="$(_make_diff 6 1)"
    result="$(_classify "$diff")"
    tier="$(_tier "$result")"
    [ "$tier" = "high" ] || _fail "expected tier=high for 6 files, got: $tier"
}

# Security-sensitive path → high regardless of LOC
test_classify_returns_high_for_security_path() {
    local diff result tier
    diff="diff --git a/auth/login.py b/auth/login.py\n--- a/auth/login.py\n+++ b/auth/login.py\n@@ -1 +1 @@\n-x\n+y\n"
    result="$(_classify "$(printf '%b' "$diff")")"
    tier="$(_tier "$result")"
    [ "$tier" = "high" ] || _fail "expected tier=high for security path auth/, got: $tier"
}

# Public API path → high
test_classify_returns_high_for_public_api_change() {
    local diff result tier
    diff="diff --git a/mylib/__init__.py b/mylib/__init__.py\n--- a/mylib/__init__.py\n+++ b/mylib/__init__.py\n@@ -1 +1 @@\n-x\n+y\n"
    result="$(_classify "$(printf '%b' "$diff")")"
    tier="$(_tier "$result")"
    [ "$tier" = "high" ] || _fail "expected tier=high for __init__.py, got: $tier"
}

# Migration path → high
test_classify_returns_high_for_migration_file() {
    local diff result tier
    diff="diff --git a/db/migrations/0042_add_users.py b/db/migrations/0042_add_users.py\n--- a/db/migrations/0042_add_users.py\n+++ b/db/migrations/0042_add_users.py\n@@ -1 +1 @@\n-x\n+y\n"
    result="$(_classify "$(printf '%b' "$diff")")"
    tier="$(_tier "$result")"
    [ "$tier" = "high" ] || _fail "expected tier=high for migration file, got: $tier"
}

# AC: config missing → loads defaults and returns a tier (no crash)
test_classify_uses_defaults_when_config_missing() {
    local diff result
    diff="$(_make_diff 1 1)"
    # Pass a non-existent config path explicitly
    result="$(_classify "$diff" "/tmp/nonexistent-quick-mode-config-$$.md")"
    [ -n "$result" ] || _fail "expected JSON output even when config is missing"
    tier="$(_tier "$result")"
    [ "$tier" = "low" ] || _fail "expected low tier for 1-file 1-line diff with defaults, got: $tier"
}

# ---------------------------------------------------------------------------
# Tests: is_quick_mode_safe_category()
# ---------------------------------------------------------------------------

# AC: known category → true
test_is_safe_category_returns_true_for_known_category() {
    local result
    result="$(python3 "$SCRIPT" --check-category "doc-only" 2>/dev/null)"
    safe="$(printf '%s' "$result" | python3 -c "import json,sys; print(str(json.load(sys.stdin)['safe']).lower())")"
    [ "$safe" = "true" ] || _fail "expected safe=true for 'doc-only', got: $safe"
}

# AC: unknown category → false
test_is_safe_category_returns_false_for_unknown_category() {
    local result
    result="$(python3 "$SCRIPT" --check-category "security-patch" 2>/dev/null)"
    safe="$(printf '%s' "$result" | python3 -c "import json,sys; print(str(json.load(sys.stdin)['safe']).lower())")"
    [ "$safe" = "false" ] || _fail "expected safe=false for 'security-patch', got: $safe"
}

# Category check is case-insensitive
test_is_safe_category_case_insensitive() {
    local result
    result="$(python3 "$SCRIPT" --check-category "DOC-ONLY" 2>/dev/null)"
    safe="$(printf '%s' "$result" | python3 -c "import json,sys; print(str(json.load(sys.stdin)['safe']).lower())")"
    [ "$safe" = "true" ] || _fail "expected safe=true for 'DOC-ONLY' (case-insensitive), got: $safe"
}

run_all_tests
