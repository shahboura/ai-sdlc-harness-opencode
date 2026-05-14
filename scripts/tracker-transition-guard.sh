#!/usr/bin/env bash
# ---
# name: tracker-transition-guard
# event: PreToolUse
# matcher: "Write|Edit|MultiEdit"
# scope: workspace
# blocking: true
# policy: fail-closed on illegal transitions; fail-open on unparseable edits
# description: >
#   Validate that every task-tracker status change in a Write/Edit/MultiEdit
#   follows the legal transition graph. Applies the edit in-memory to the
#   on-disk tracker, diffs task-row statuses by ID, and validates every
#   transition that actually changed (not just the first one).
#
#   Legal transitions:
#     ⏳ Pending     → 🔧 In Progress
#     🔧 In Progress → 🔄 In Review
#     🔄 In Review   → ✅ Done           (reviewer approved)
#     🔄 In Review   → 🔧 In Progress    (changes requested)
#     ✅ Done        → 🔧 In Progress    (rework)
#
#   Metadata-only edits (Notes, Commit hashes, timestamps) pass through.
# ---
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_hook-lib.sh"

if ! hook_in_workspace; then
    exit 0
fi

hook_init || exit 0

exec "$(hook_python)" "$DIR/_tracker_transition_guard.py" "$HOOK_PAYLOAD_FILE"
