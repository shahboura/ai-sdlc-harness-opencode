#!/usr/bin/env bash
# ---
# name: sensitive-file-guard
# event: PreToolUse
# matcher: "Write|Edit|MultiEdit|NotebookEdit"
# scope: workspace
# blocking: true
# policy: fail-CLOSED
# description: >
#   Block Write/Edit/MultiEdit/NotebookEdit operations whose target file
#   matches a sensitive-file pattern (.env*, *.pem, id_rsa*, *.tfstate*,
#   *.kdbx, .netrc, .npmrc, credentials*, secrets.*, etc.).
#
#   The Bash side of this protection lives in `bash-write-guard.sh`; both
#   guards share `_sensitive_patterns.py` so the deny-list stays in sync.
# ---
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_hook-lib.sh"

if ! hook_in_workspace; then
    exit 0
fi

hook_init || exit 0

exec "$(hook_python)" "$DIR/_sensitive_file_guard.py" "$HOOK_PAYLOAD_FILE"
