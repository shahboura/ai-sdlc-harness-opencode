#!/usr/bin/env bash
# Hook: validate-mermaid-syntax
# Event: PreToolUse
# Matcher: Write|Edit|MultiEdit
# Policy: fail-closed (CC-07.4.2 — block writes that emit invalid Mermaid)
# Enforces: every Mermaid fence inside a Markdown write/edit must pass structural validation per CC-07.4.1.
# Reads context from: hook payload JSON at $1; the on-disk file referenced by payload.tool_input.file_path
# Writes side-effects to: stdout (PASS) / stderr (FAIL); never modifies files
#
# Created by: dev-workflow-plan.md [M-16] [IMPL-16-03]
# Reason: CC-07.4 / GAP-23 — block writes that ship broken Mermaid.
# CC conventions applied: CC-03.4 (wrapper template), CC-03.8 (header block), CC-03.2 (fail-closed).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_hook-lib.sh"

if ! hook_in_workspace; then
    exit 0
fi

hook_init || exit 0

# The Python backer reads the hook payload JSON from $HOOK_PAYLOAD_FILE,
# resolves the post-edit content, and fast-paths return 0 for files that
# don't contain a ```mermaid fence. Wrapper-side filtering is intentionally
# minimal — payload parsing belongs in the Python.
exec "$(hook_python)" "$DIR/_validate_mermaid_syntax.py" "$HOOK_PAYLOAD_FILE"
