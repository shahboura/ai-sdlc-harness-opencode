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
# JSON, e.g. mk_bash_payload "git commit ..." '{"agent_type": "reviewer"}'
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

# Build a `tool_name=Write` payload.
mk_write_payload() {
    local path="$1"
    local content="$2"
    python3 -c "
import json, sys
print(json.dumps({
    'tool_name': 'Write',
    'tool_input': {'file_path': sys.argv[1], 'content': sys.argv[2]},
}))
" "$path" "$content"
}

# Build a `tool_name=Edit` payload.
mk_edit_payload() {
    local path="$1"
    local old="$2"
    local new="$3"
    python3 -c "
import json, sys
print(json.dumps({
    'tool_name': 'Edit',
    'tool_input': {
        'file_path': sys.argv[1],
        'old_string': sys.argv[2],
        'new_string': sys.argv[3],
    },
}))
" "$path" "$old" "$new"
}

# Build a `tool_name=MultiEdit` payload. Edits are passed as a JSON array:
# mk_multiedit_payload <path> '[{"old_string":"a","new_string":"b"}, …]'
mk_multiedit_payload() {
    local path="$1"
    local edits_json="$2"
    python3 -c "
import json, sys
print(json.dumps({
    'tool_name': 'MultiEdit',
    'tool_input': {
        'file_path': sys.argv[1],
        'edits': json.loads(sys.argv[2]),
    },
}))
" "$path" "$edits_json"
}

# Build a `tool_name=NotebookEdit` payload.
mk_notebook_payload() {
    local path="$1"
    python3 -c "
import json, sys
print(json.dumps({
    'tool_name': 'NotebookEdit',
    'tool_input': {'notebook_path': sys.argv[1]},
}))
" "$path"
}

# Build a `tool_name=Agent` payload (PostToolUse on Agent). Optional 2nd arg
# is the subagent_type (e.g. 'reviewer'); 3rd arg is the orchestrator
# prompt that the agent received.
mk_agent_payload() {
    local response="$1"
    local subagent_type="${2:-}"
    local prompt="${3:-}"
    python3 -c "
import json, sys
payload = {
    'tool_name': 'Agent',
    'tool_input': {
        'subagent_type': sys.argv[2] if len(sys.argv) > 2 else '',
        'prompt': sys.argv[3] if len(sys.argv) > 3 else '',
    },
    'tool_response': sys.argv[1],
}
print(json.dumps(payload))
" "$response" "$subagent_type" "$prompt"
}

# Build a SubagentStop payload. Response can be either a string or a JSON
# array of content blocks (passed as a string).
mk_subagentstop_payload() {
    local response="$1"
    python3 -c "
import json, sys
print(json.dumps({'response': sys.argv[1]}))
" "$response"
}

# Write a file inside FAKE_WORKSPACE. Used by tracker-transition-guard tests
# that need a real on-disk tracker.
write_fixture() {
    local rel_path="$1"
    local content="$2"
    local full="$FAKE_WORKSPACE/$rel_path"
    mkdir -p "$(dirname "$full")"
    printf '%s' "$content" > "$full"
    printf '%s' "$full"
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
