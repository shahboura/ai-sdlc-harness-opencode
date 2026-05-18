#!/usr/bin/env bash
# Hook: stop-failure-recovery
# Event: UserPromptSubmit
# Matcher: ""
# Policy: fail-open
# Enforces: emits recovery context onto the prompt when .stop-failure marker is present; never blocks.
# Reads context from: workspace walk-up; .claude/context/.stop-failure; ai/.snapshots/
# Writes side-effects to: deletes .claude/context/.stop-failure (one-shot)
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
#
# Updated by: dev-workflow-plan.md [M-08] [IMPL-08-04]
# Reason: Add canonical CC-03.8 header block (Hook/Event/Matcher/Policy/Enforces/Reads/Writes) per TEST-49.
# CC conventions applied: CC-03.2 (fail-open declared), CC-03.3 (isolation: only deletes the marker), CC-03.8 (canonical header block).
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

# Detect orphan plan snapshots — written by handle-request.md Step 5 "Expand
# scope" before MODE: plan-amendment, and normally cleaned up on the
# amendment's approval/rejection. If a snapshot exists at recovery time, the
# session was interrupted mid-amendment and the plan file may carry text the
# human never approved.
SNAPSHOT_DIR="$WS_ROOT/ai/.snapshots"
SNAPSHOT_BLOCK=""
if [ -d "$SNAPSHOT_DIR" ]; then
    # Use a portable find — newest first via mtime sort.
    snapshots="$(find "$SNAPSHOT_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort -r)"
    if [ -n "$snapshots" ]; then
        # Emit one line per snapshot for the recovery prompt to consume.
        SNAPSHOT_BLOCK="$(printf '%s\n' "$snapshots")"
    fi
fi

# Split into two cat blocks to keep the parameter expansion off any
# multi-line boundary — pre-C8, the recovery prompt used a single heredoc with
# an `${SNAPSHOT_BLOCK:+...}` expansion that spanned multiple lines and
# embedded an unmatched-looking `}` on its own line. Functional but fragile:
# any future edit that broke a brace boundary silently turned the entire
# recovery prompt into a no-op. The split makes each block self-contained.

cat <<EOF
[SYSTEM — API ERROR RECOVERY: An API error ended the previous turn. Before responding to the user's message, check whether ai/tasks/ contains any .md tracker files. If none exist, skip this entirely and respond normally. Otherwise: read the most recent tracker in ai/tasks/. Identify tasks marked In Progress or In Review — these were likely active when the failure hit. Check 'git status --porcelain' for uncommitted changes. If .claude/context/repos-paths.md exists, also check each repo for uncommitted changes. Then run worktree reconciliation: for each repo from repos-paths.md, run \`git -C "<repo-path>" worktree list\` and for every listed worktree whose branch name matches \`worktree/<story-id>-t<n>-<uid>\`, locate task T<n> in the tracker. Classify each worktree as: (a) preserve — task is 🔧 In Progress or 🔄 In Review (this is the worktree the resumed session will pick up); (b) remove — task is ✅ Done or there is no matching task row (stale from a prior session). **If two or more worktrees match the SAME In Progress / In Review task** (orphan from a previous crashed attempt + the current attempt's fresh worktree), pick the most recently modified one as preserve (use \`git -C "<wt>" log -1 --format=%ct HEAD\` as the tie-breaker; fall back to directory mtime if neither has commits) and classify the rest as remove with the reason "duplicate worktree for task T<n>". Do NOT remove worktrees yet — output the classification so the orchestrator can confirm with the human before pruning. Repos running in worktree-failed fallback mode (no worktrees listed) are valid; do not flag.
EOF

if [ -n "$SNAPSHOT_BLOCK" ]; then
    cat <<EOF

ADDITIONAL CHECK — orphan plan snapshot(s) detected at ai/.snapshots/. These were written by handle-request.md before invoking MODE: plan-amendment and are normally cleaned up after the amendment is approved or rejected. Their presence means an amendment was interrupted mid-flow. For each snapshot below, compare it byte-for-byte against the corresponding plan file in ai/plans/ — if the plan file has additional text the snapshot does not, that text is the unapproved amendment. Surface this to the human at recovery time with: (a) the snapshot path, (b) the diff against the current plan, (c) three options: [1] restore the plan from the snapshot (rolls back the unapproved amendment), [2] keep the plan as-is (treat the amendment as approved retroactively — requires human sign-off), [3] discard both (keep the plan, delete the snapshot). Do NOT auto-restore or auto-delete. Snapshots found:
$SNAPSHOT_BLOCK
EOF
fi

if [ -n "$SNAPSHOT_BLOCK" ]; then
    SNAPSHOT_TAIL=", and resolve the orphan plan snapshot(s)"
else
    SNAPSHOT_TAIL=""
fi

cat <<EOF

 Output: (1) which tasks were active (ID, status, description), (2) uncommitted changes with file counts per repo, (3) worktree reconciliation table (path, branch, task ID, classification), (4) recovery guidance: read the tracker, resume from the active task, verify uncommitted changes before committing, ask the human to confirm pruning the \`remove\` worktrees${SNAPSHOT_TAIL}. Do not restart completed tasks. Then respond to the user's message.]
EOF
