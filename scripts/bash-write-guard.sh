#!/usr/bin/env bash
# ---
# name: bash-write-guard
# event: PreToolUse
# matcher: "Bash"
# scope: workspace
# blocking: true
# policy: fail-closed on recognized writes; fail-open on unparseable Bash
# description: >
#   Bash-side write guard. Blocks Bash commands that:
#     1. Write to anything under `./ai/` (orchestrator-owned territory; tracker
#        and plan files must be touched via Write/Edit, not shell).
#     2. Write to sensitive file patterns (.env*, *.pem, id_rsa*, *.tfstate, …)
#        — closes the gap that sensitive-file-guard.sh leaves for Bash.
#     3. (Best-effort, when subagent identity is available in the payload):
#          - reviewer  → no file writes at all
#          - planner   → writes only under ai/
#
#   Covers redirects (>, >>, >|, &>, 2>, …), tee, cp/mv/install, ln, dd of=.
# ---
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_hook-lib.sh"

if ! hook_in_workspace; then
    exit 0
fi

hook_init || exit 0

TOOL="$(hook_field tool_name)"
[ "$TOOL" = "Bash" ] || exit 0

exec "$(hook_python)" "$DIR/_bash_write_guard.py" "$HOOK_PAYLOAD_FILE"
