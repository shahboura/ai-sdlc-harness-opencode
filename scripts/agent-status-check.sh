#!/usr/bin/env bash
# ---
# name: agent-status-check
# event: SubagentStop
# matcher: ""
# scope: workspace
# blocking: true
# policy: fail-CLOSED when response extractable; fail-OPEN otherwise
# description: >
#   Enforce that every subagent response ends with a properly-shaped
#   `📋 AGENT STATUS` block. The phrase must appear in the response's final
#   ~50 lines AND the block must contain at least one of `Outcome:` or
#   `Verdict:` so blocks with only the literal header don't pass.
# ---
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_hook-lib.sh"

if ! hook_in_workspace; then
    exit 0
fi

hook_init || exit 0

exec "$(hook_python)" "$DIR/_agent_status_check.py" "$HOOK_PAYLOAD_FILE"
