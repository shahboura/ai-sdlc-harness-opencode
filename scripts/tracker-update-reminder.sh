#!/usr/bin/env bash
# ---
# name: tracker-update-reminder
# event: PostToolUse
# matcher: "Agent"
# scope: workspace
# blocking: false
# policy: fail-OPEN (advisory)
# description: >
#   After every subagent invocation, parse the AGENT STATUS block from the
#   response, determine what the tracker SHOULD show for the task, compare
#   against current tracker state, and emit a reminder via
#   hookSpecificOutput.additionalContext when they diverge. Never blocks.
# ---
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_hook-lib.sh"

if ! hook_in_workspace; then
    exit 0
fi

hook_init || exit 0

exec "$(hook_python)" "$DIR/_tracker_update_reminder.py" "$HOOK_PAYLOAD_FILE"
