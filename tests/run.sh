#!/usr/bin/env bash
# Top-level aggregator: runs the hooks suite, the skills suite, and the
# integration suite. Single entry point for CI and local runs.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

total_fail=0
suites=()

run_dir_aggregator() {
    local label="$1"
    local script="$2"
    suites+=("$label")
    printf '\n########  %s  ########\n' "$label"
    if [ -x "$script" ] || [ -f "$script" ]; then
        if ! bash "$script"; then
            total_fail=$((total_fail + 1))
            printf '  → suite "%s" failed\n' "$label" >&2
        fi
    else
        printf '  (no aggregator at %s — skipping)\n' "$script"
    fi
}

run_integration_dir() {
    local dir="$DIR/integration"
    if [ ! -d "$dir" ]; then
        return 0
    fi
    suites+=("integration")
    printf '\n########  integration  ########\n'
    for test_file in "$dir"/*/test.sh; do
        [ -f "$test_file" ] || continue
        name="$(basename "$(dirname "$test_file")")"
        printf '\n=== integration/%s ===\n' "$name"
        if ! bash "$test_file"; then
            total_fail=$((total_fail + 1))
        fi
    done
}

run_dir_aggregator "hooks"    "$DIR/hooks/run.sh"
run_dir_aggregator "skills"   "$DIR/skills/run.sh"
run_dir_aggregator "adapters" "$DIR/adapters/run.sh"
run_integration_dir

# Convention-Check aggregator (IMPL-13-03) — runs every script under
# tests/convention-check/ via scripts/cc-check.py. Treated as a separate
# logical suite for reporting; surfaces STRICT-layer convention drift at
# the same severity as unit/skill/hook/integration failures. Advisory-
# layer checks (e.g. CC-09 prose, CC-0507 during M-14 migration) exit 0
# even when violations exist — only fail-closed checks bump total_fail.
run_cc_check_aggregator() {
    local script="$DIR/../scripts/cc-check.py"
    if [ ! -f "$script" ]; then
        return 0
    fi
    suites+=("convention-check")
    printf '\n########  convention-check  ########\n'
    if ! python3 "$script"; then
        total_fail=$((total_fail + 1))
        printf '  → convention-check aggregator reported failure\n' >&2
    fi
}
run_cc_check_aggregator

printf '\n=====================================\n'
if [ "$total_fail" -gt 0 ]; then
    printf '%d suite(s) failed across: %s\n' "$total_fail" "${suites[*]}" >&2
    exit 1
fi
printf 'All suites passed across: %s\n' "${suites[*]}"
