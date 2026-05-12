#!/usr/bin/env bash
# Shared assertions for hook tests.
#
# Tests are bash files that define `test_<name>` functions and call
# `run_all_tests` at the end. Each test function uses one of:
#
#   assert_hook_allows  <script> <payload-json>
#   assert_hook_blocks  <script> <payload-json>  [<stderr-substring>]
#
# The harness sets up a fake "initialised workspace" (a tempdir containing
# .claude/context/provider-config.md) and cd's into it so the hooks'
# `hook_in_workspace` gate passes.

set -uo pipefail

# Resolve repo root from this file's location.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../../.." && pwd)"

# Counters
TEST_PASS=0
TEST_FAIL=0
TEST_FAILURES=()
CURRENT_TEST=""

repo_root() {
    printf '%s' "$REPO_ROOT"
}

# Build a `tool_name=Bash` payload for a given bash command. Handles all
# JSON escaping. Optional second argument adds extra top-level fields as
# JSON, e.g. mk_bash_payload "git commit ..." '{"subagent_name": "reviewer"}'
mk_bash_payload() {
    local cmd="$1"
    local extras="${2:-}"
    python3 -c "
import json, sys
base = {'tool_name': 'Bash', 'tool_input': {'command': sys.argv[1]}}
if len(sys.argv) > 2 and sys.argv[2]:
    base.update(json.loads(sys.argv[2]))
print(json.dumps(base))
" "$cmd" "$extras"
}

_setup_workspace() {
    FAKE_WORKSPACE="$(mktemp -d -t hooktest.XXXXXX)"
    mkdir -p "$FAKE_WORKSPACE/.claude/context"
    : > "$FAKE_WORKSPACE/.claude/context/provider-config.md"
}

_teardown_workspace() {
    if [ -n "${FAKE_WORKSPACE:-}" ] && [ -d "$FAKE_WORKSPACE" ]; then
        rm -rf "$FAKE_WORKSPACE"
    fi
}

_run_hook() {
    # _run_hook <script> <payload>  → echoes "<exit_code>\t<stderr>"
    local script="$1"
    local payload="$2"
    local stderr_file
    stderr_file="$(mktemp)"
    local stdout_file
    stdout_file="$(mktemp)"
    local exit_code=0
    (
        cd "$FAKE_WORKSPACE"
        printf '%s' "$payload" | "$script" >"$stdout_file" 2>"$stderr_file"
    ) || exit_code=$?
    local stderr
    stderr="$(cat "$stderr_file")"
    rm -f "$stdout_file" "$stderr_file"
    printf '%d\t%s' "$exit_code" "$stderr"
}

assert_hook_allows() {
    local script="$1"
    local payload="$2"
    local result exit_code stderr
    result="$(_run_hook "$script" "$payload")"
    exit_code="${result%%$'\t'*}"
    stderr="${result#*$'\t'}"
    if [ "$exit_code" != "0" ]; then
        _fail "expected exit 0 (allow), got $exit_code
stderr:
$stderr
payload: $payload"
        return 1
    fi
    return 0
}

assert_hook_blocks() {
    local script="$1"
    local payload="$2"
    local needle="${3:-}"
    local result exit_code stderr
    result="$(_run_hook "$script" "$payload")"
    exit_code="${result%%$'\t'*}"
    stderr="${result#*$'\t'}"
    if [ "$exit_code" != "2" ]; then
        _fail "expected exit 2 (block), got $exit_code
stderr:
$stderr
payload: $payload"
        return 1
    fi
    if [ -n "$needle" ] && ! printf '%s' "$stderr" | grep -qF "$needle"; then
        _fail "expected stderr to contain: $needle
got stderr:
$stderr
payload: $payload"
        return 1
    fi
    return 0
}

_fail() {
    TEST_FAIL=$((TEST_FAIL + 1))
    TEST_FAILURES+=("$CURRENT_TEST: $*")
    printf '  FAIL  %s\n' "$CURRENT_TEST" >&2
    printf '        %s\n' "$1" | sed -e 's/^/        /' >&2
}

_pass() {
    TEST_PASS=$((TEST_PASS + 1))
    printf '  ok    %s\n' "$CURRENT_TEST"
}

run_all_tests() {
    _setup_workspace
    trap _teardown_workspace EXIT

    # Discover test_* functions and run each.
    local fns
    fns="$(declare -F | awk '$3 ~ /^test_/ {print $3}')"
    if [ -z "$fns" ]; then
        printf 'No tests found.\n' >&2
        return 1
    fi
    local fn
    for fn in $fns; do
        CURRENT_TEST="$fn"
        local before_fail=$TEST_FAIL
        "$fn"
        if [ "$TEST_FAIL" = "$before_fail" ]; then
            _pass
        fi
    done

    printf '\n%d passed, %d failed\n' "$TEST_PASS" "$TEST_FAIL"
    if [ "$TEST_FAIL" -gt 0 ]; then
        printf '\nFailures:\n' >&2
        local f
        for f in "${TEST_FAILURES[@]}"; do
            printf '  - %s\n' "$f" >&2
        done
        return 1
    fi
    return 0
}
