#!/usr/bin/env bash
# ---
# name: squash-merge-verify
# event: PostToolUse
# matcher: "Bash"
# scope: workspace
# blocking: false
# policy: fail-OPEN (advisory; PostToolUse exit 2 surfaces a warning)
# description: >
#   After a `git merge --squash` invocation, verify the operation landed
#   cleanly. On conflict: print recovery instructions and exit 2 to surface
#   the warning to the model. On success with staged changes: print a
#   one-line confirmation.
#
#   Handles chained commands (`cd X && git merge --squash …`), env-var
#   prefixes, subshell wrapping, and `git -c <cfg>` config flags.
# ---
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_hook-lib.sh"

if ! hook_in_workspace; then
    exit 0
fi

hook_init || exit 0

exec "$(hook_python)" "$DIR/_squash_merge_verify.py" "$HOOK_PAYLOAD_FILE"
