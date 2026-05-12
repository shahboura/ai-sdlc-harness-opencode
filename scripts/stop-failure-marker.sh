#!/usr/bin/env bash
# ---
# name: stop-failure-marker
# event: StopFailure
# matcher: ""
# scope: workspace
# blocking: false
# policy: fail-OPEN (advisory)
# description: >
#   Write a marker file under the workspace's .claude/context/ when a turn
#   ends with an API stop failure. The matching `stop-failure-recovery.sh`
#   hook on the next UserPromptSubmit detects this marker and injects
#   recovery instructions.
#
#   Uses workspace walk-up (not cwd) so the marker is written even if the
#   orchestrator changed directory before the failure.
# ---
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_hook-lib.sh"

WS_ROOT="$(hook_workspace_root 2>/dev/null || true)"
if [ -z "$WS_ROOT" ]; then
    exit 0
fi

touch "$WS_ROOT/.claude/context/.stop-failure" 2>/dev/null || true
exit 0
