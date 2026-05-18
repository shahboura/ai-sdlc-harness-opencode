#!/usr/bin/env bash
# ---
# name: worktree-clean-check
# event: SubagentStop
# matcher: ""
# scope: workspace
# blocking: true
# policy: fail-CLOSED when developer/tester reports SUCCESS with a dirty
#   worktree; fail-OPEN in every other condition (block unparseable, agent
#   out of scope, path unresolvable, non-git directory)
# description: >
#   Prevent the "agent reports SUCCESS but didn't commit" failure mode
#   (orchestrator historically committed on behalf, violating CC-02.1).
#   When developer or tester emits `Outcome: SUCCESS`, verify
#   `git -C <worktree-path> status --porcelain` is empty. If not, block
#   with a clear recovery prompt pointing at the soft-cap WIP-checkpoint
#   contract.
# ---
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_hook-lib.sh"

if ! hook_in_workspace; then
    exit 0
fi

hook_init || exit 0

exec "$(hook_python)" "$DIR/_worktree_clean_check.py" "$HOOK_PAYLOAD_FILE"
