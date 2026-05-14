#!/usr/bin/env bash
# Runs every test.sh under tests/skills/. Doc-grep regression coverage for
# the skill markdown files (no fake workspace needed; tests grep directly
# against tracked files in the repo).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

total_fail=0
for test_file in "$DIR"/*.test.sh; do
    [ -f "$test_file" ] || continue
    suite_name="$(basename "$test_file" .test.sh)"
    printf '\n=== skills/%s ===\n' "$suite_name"
    if ! bash "$test_file"; then
        total_fail=$((total_fail + 1))
    fi
done

if [ "$total_fail" -gt 0 ]; then
    printf '\n%d skills suite(s) failed.\n' "$total_fail" >&2
    exit 1
fi
printf '\nAll skills suites passed.\n'
