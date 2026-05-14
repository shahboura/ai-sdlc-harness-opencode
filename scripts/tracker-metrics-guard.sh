#!/usr/bin/env bash
# ---
# name: tracker-metrics-guard
# event: PreToolUse
# matcher: "Edit"
# scope: workspace
# blocking: false
# policy: fail-OPEN (advisory)
# description: >
#   Warn when timestamp values written to the Workflow Metrics and Task
#   Metrics sections of the task tracker do not use the full
#   YYYY-MM-DD HH:MM UTC format. Always exits 0 so the edit proceeds.
# ---
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_hook-lib.sh"

if ! hook_in_workspace; then
    exit 0
fi

hook_init || exit 0

exec "$(hook_python)" "$DIR/_tracker_metrics_guard.py" "$HOOK_PAYLOAD_FILE"
