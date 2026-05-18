#!/usr/bin/env bash
# Hook: stop-failure-marker
# Event: StopFailure
# Matcher: ""
# Policy: fail-open
# Enforces: writes .claude/context/.stop-failure marker on turn-end-with-failure so the next prompt can route to recovery.
# Reads context from: workspace walk-up
# Writes side-effects to: .claude/context/.stop-failure
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
#
# Updated by: dev-workflow-plan.md [M-08] [IMPL-08-04]
# Reason: Add canonical CC-03.8 header block (Hook/Event/Matcher/Policy/Enforces/Reads/Writes) per TEST-49.
# CC conventions applied: CC-03.2 (fail-open declared), CC-03.8 (canonical header block).
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
