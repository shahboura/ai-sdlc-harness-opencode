#!/usr/bin/env bash
# ---
# name: validate-commit-msg
# event: PreToolUse
# matcher: "Bash"
# scope: workspace
# blocking: true
# policy: fail-CLOSED
# description: >
#   Validate that `git commit` invocations follow the harness convention:
#     #<STORY-ID> #<TASK-ID>: <imperative description>
#   Plus exceptions for the TDD subject prefixes, the Phase 5 test-harden
#   form, and git's autosquash markers (fixup!/squash!/amend!/reword!).
#
#   Parsing handles `git -C <path>`, env-var prefixes, chained commands,
#   multiple -m flags, --message=, -F, --amend, and heredoc bodies passed
#   via `$(cat <<TAG ... TAG)`.
#
#   If the parser cannot reconstruct the commit message, the hook blocks.
# ---
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_hook-lib.sh"

# Scope guard: only run inside an initialised harness workspace.
if ! hook_in_workspace; then
    exit 0
fi

hook_init || exit 0

TOOL="$(hook_field tool_name)"
[ "$TOOL" = "Bash" ] || exit 0

COMMAND="$(hook_field tool_input.command)"
[ -n "$COMMAND" ] || exit 0

# Quick gate: must look like it could be a git commit. Avoids the python
# spawn cost on every Bash call.
case "$COMMAND" in
    *git*commit*) : ;;
    *) exit 0 ;;
esac

exec "$(hook_python)" "$DIR/_validate_commit_msg.py" "$COMMAND"
