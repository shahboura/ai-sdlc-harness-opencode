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

printf '\n=====================================\n'
if [ "$total_fail" -gt 0 ]; then
    printf '%d suite(s) failed across: %s\n' "$total_fail" "${suites[*]}" >&2
    exit 1
fi
printf 'All suites passed across: %s\n' "${suites[*]}"
