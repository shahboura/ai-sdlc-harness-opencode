#!/usr/bin/env bash
# Runs every test.sh under tests/adapters/. Covers provider-adapter capability
# declarations against the canonical list in skills/providers/shared/capabilities.md.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

total_fail=0
for test_file in "$DIR"/*/test.sh; do
    [ -f "$test_file" ] || continue
    suite_name="$(basename "$(dirname "$test_file")")"
    printf '\n=== adapters/%s ===\n' "$suite_name"
    if ! bash "$test_file"; then
        total_fail=$((total_fail + 1))
    fi
done

if [ "$total_fail" -gt 0 ]; then
    printf '\n%d adapter suite(s) failed.\n' "$total_fail" >&2
    exit 1
fi
printf '\nAll adapter suites passed.\n'
