#!/usr/bin/env bash
# ---
# name: tester-activation-guard
# event: SubagentStart
# matcher: "tester"
# scope: workspace
# blocking: true
# policy: fail-closed on invalid tracker state; mode-aware (auto-tdd vs auto-harden)
# description: >
#   Mode-aware guard for the Tester agent.
#
#   auto-tdd mode (Phase 3):  Allow when ≥1 task is 🔧 In Progress.
#   auto-harden mode (Phase 5):  Block unless every dev task (T1, T2, …) is
#   ✅ Done. T-TEST rows are excluded.
#
#   Mode is detected from CLAUDE_SUBAGENT_PROMPT (populated by the harness).
#   Status-column position is detected from the tracker header rather than
#   assumed at a fixed index, so new tracker columns do not break detection.
# ---
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_hook-lib.sh"

if ! hook_in_workspace; then
    exit 0
fi

hook_init || exit 0

exec "$(hook_python)" "$DIR/_tester_activation_guard.py" "$HOOK_PAYLOAD_FILE"
