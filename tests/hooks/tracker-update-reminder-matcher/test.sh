#!/usr/bin/env bash
# C9 regression: the `tracker-update-reminder` hook's PostToolUse matcher in
# hooks/hooks.json must agree with the `tool_name` value the test fixture
# emits in `mk_agent_payload`. If they ever diverge (e.g. Claude Code renames
# the sub-agent tool from `Agent` to `Task` and the fixture is updated but
# the matcher isn't, or vice-versa), the hook silently stops firing on every
# subagent completion — and the existing reminder tests would still pass
# because they invoke the script directly, bypassing the matcher.
#
# This test pins the matcher-vs-fixture link so the divergence fails build.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
ASSERT_SH="$REPO_ROOT/tests/hooks/lib/assert.sh"

# Extract the PostToolUse matcher used by tracker-update-reminder.
MATCHER=$(python3 -c "
import json
with open('$HOOKS_JSON') as f:
    data = json.load(f)
for entry in data.get('hooks', {}).get('PostToolUse', []):
    for hook in entry.get('hooks', []):
        cmd = hook.get('command', '')
        if 'tracker-update-reminder.sh' in cmd:
            print(entry.get('matcher', ''))
            break
")

if [ -n "$MATCHER" ]; then
    _pass "tracker-update-reminder registers a PostToolUse matcher (got: '$MATCHER')"
else
    _fail 'tracker-update-reminder registers a PostToolUse matcher' \
        'could not find tracker-update-reminder.sh in hooks/hooks.json PostToolUse entries'
fi

# Extract the tool_name used by mk_agent_payload in the test helper.
FIXTURE_TOOL_NAME=$(grep -oE "'tool_name': '[^']+'" "$ASSERT_SH" | head -1 | sed -E "s/'tool_name': '([^']+)'/\1/")
# Get the one specifically inside mk_agent_payload (assert.sh has several
# mk_*_payload functions; the Agent one is the relevant pairing).
FIXTURE_TOOL_NAME=$(awk '/^mk_agent_payload\(\)/,/^}/' "$ASSERT_SH" | grep -oE "'tool_name': '[^']+'" | head -1 | sed -E "s/'tool_name': '([^']+)'/\1/")

if [ -n "$FIXTURE_TOOL_NAME" ]; then
    _pass "mk_agent_payload mocks tool_name (got: '$FIXTURE_TOOL_NAME')"
else
    _fail 'mk_agent_payload mocks tool_name' \
        'could not extract tool_name from mk_agent_payload in tests/hooks/lib/assert.sh'
fi

# The two must agree — otherwise the hook silently stops firing in production
# while the unit tests (which call the script directly, bypassing the matcher)
# continue to pass.
if [ "$MATCHER" = "$FIXTURE_TOOL_NAME" ]; then
    _pass "matcher and test fixture tool_name agree ('$MATCHER')"
else
    _fail "matcher and test fixture tool_name agree" \
        "matcher='$MATCHER' but fixture tool_name='$FIXTURE_TOOL_NAME' — the hook would not fire in production"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0
