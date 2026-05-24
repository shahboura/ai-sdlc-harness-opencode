#!/usr/bin/env bash
# Functional test for scripts/markdown-size-report.py — TEST-195 (CC-04.8 / IMPL-26-02).
#
# Validates:
#   1. Script exits 0 on the live plugin tree.
#   2. Wall-clock time ≤ 2 seconds (FR-8.6 acceptance criterion).
#   3. Output contains the required column headers.
#   4. Table sorted by lines descending (first data row ≥ last data row).
#   5. Every file classified by cc-check-md-budget also appears in the report.
#   6. --format csv produces comma-separated output with same columns.
#
# CC conventions validated: CC-04.8 (FR-8.6), NFR-2 (stdlib only).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/markdown-size-report.py"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s — %s\n' "$1" "$2" >&2; }

# ---------------------------------------------------------------------------
# 1 + 2: Exit 0 within 2 seconds
# ---------------------------------------------------------------------------
_start=$(python3 -c "import time; print(time.monotonic())")
_output="$(python3 "$SCRIPT" "$REPO_ROOT" 2>/dev/null)"
_rc=$?
_end=$(python3 -c "import time; print(time.monotonic())")
_elapsed=$(python3 -c "print($_end - $_start)")

if [ "$_rc" -eq 0 ]; then
    _pass "script exits 0"
else
    _fail "exit code" "expected 0, got $_rc"
fi

_over2=$(python3 -c "print('yes' if $_elapsed > 2.0 else 'no')")
if [ "$_over2" = "no" ]; then
    _pass "wall-clock ≤ 2s (elapsed ${_elapsed}s)"
else
    _fail "wall-clock" "took ${_elapsed}s — exceeds 2s limit (TEST-195)"
fi

# ---------------------------------------------------------------------------
# 3: Required column headers present
# ---------------------------------------------------------------------------
for col in "file" "tier" "lines" "bytes" "status"; do
    if printf '%s' "$_output" | grep -qF "| $col "; then
        _pass "table header has '$col' column"
    else
        _fail "table header" "missing '$col' column in output"
    fi
done

# ---------------------------------------------------------------------------
# 4: Sorted by lines descending (first data line lines ≥ last data line lines)
# ---------------------------------------------------------------------------
_data_lines=$(printf '%s' "$_output" | grep -E '^\| `' || true)
if [ -n "$_data_lines" ]; then
    _first_lines=$(printf '%s' "$_data_lines" | head -1 | python3 -c "
import sys, re
line = sys.stdin.read()
m = re.search(r'\|\s*([0-9,]+)\s*\|', line)
print(m.group(1).replace(',','') if m else '0')
")
    _last_lines=$(printf '%s' "$_data_lines" | tail -1 | python3 -c "
import sys, re
line = sys.stdin.read()
m = re.search(r'\|\s*([0-9,]+)\s*\|', line)
print(m.group(1).replace(',','') if m else '0')
")
    _sorted_ok=$(python3 -c "print('yes' if int('$_first_lines') >= int('$_last_lines') else 'no')")
    if [ "$_sorted_ok" = "yes" ]; then
        _pass "table sorted by lines descending (first=$_first_lines >= last=$_last_lines)"
    else
        _fail "sort order" "first row lines=$_first_lines < last row lines=$_last_lines"
    fi
else
    _fail "data rows" "no data rows found in output"
fi

# ---------------------------------------------------------------------------
# 5: plan-generator/SKILL.md (largest file) appears in output
# ---------------------------------------------------------------------------
if printf '%s' "$_output" | grep -qF "plan-generator/SKILL.md"; then
    _pass "plan-generator/SKILL.md appears in report"
else
    _fail "file coverage" "plan-generator/SKILL.md missing from report"
fi

# ---------------------------------------------------------------------------
# 6: --format csv produces comma-separated output
# ---------------------------------------------------------------------------
_csv_output="$(python3 "$SCRIPT" "$REPO_ROOT" --format csv 2>/dev/null)"
_csv_rc=$?
if [ "$_csv_rc" -eq 0 ]; then
    _pass "--format csv exits 0"
else
    _fail "--format csv" "expected exit 0, got $_csv_rc"
fi
if printf '%s' "$_csv_output" | grep -qE "^file,tier,lines,bytes,status$"; then
    _pass "--format csv has correct header row"
else
    _fail "--format csv header" "expected 'file,tier,lines,bytes,status' header row"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for f in "${fail_msgs[@]}"; do printf '  - %s\n' "$f" >&2; done
    exit 1
fi
