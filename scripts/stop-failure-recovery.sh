#!/usr/bin/env bash
# ---
# name: stop-failure-recovery
# event: UserPromptSubmit
# matcher: ""
# scope: workspace
# blocking: false
# policy: fail-OPEN (advisory; appends context to the prompt)
# description: >
#   On the first UserPromptSubmit after a StopFailure, check the workspace
#   for the `.stop-failure` marker written by `stop-failure-marker.sh`.
#   If present, delete the marker and emit a recovery instructions block
#   on stdout — Claude Code appends it to the user's prompt as additional
#   context. Marker deletion is unconditional so it fires exactly once.
#
#   Uses workspace walk-up (not cwd) so it works even when the
#   orchestrator has changed directory.
# ---
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_hook-lib.sh"

WS_ROOT="$(hook_workspace_root 2>/dev/null || true)"
if [ -z "$WS_ROOT" ]; then
    exit 0
fi

MARKER="$WS_ROOT/.claude/context/.stop-failure"
if [ ! -f "$MARKER" ]; then
    exit 0
fi

rm -f "$MARKER"

cat <<'EOF'
[SYSTEM — API ERROR RECOVERY: An API error ended the previous turn. Before responding to the user's message, check whether ai/tasks/ contains any .md tracker files. If none exist, skip this entirely and respond normally. Otherwise: read the most recent tracker in ai/tasks/. Identify tasks marked In Progress or In Review — these were likely active when the failure hit. Check 'git status --porcelain' for uncommitted changes. If .claude/context/repos-paths.md exists, also check each repo for uncommitted changes. Output: (1) which tasks were active (ID, status, description), (2) uncommitted changes with file counts, (3) recovery guidance: read the tracker, resume from the active task, verify uncommitted changes before committing. Do not restart completed tasks. Then respond to the user's message.]
EOF
