#!/usr/bin/env bash
# Hook: tdd-red-verify
# Event: PostToolUse
# Matcher: Bash
# Policy: fail-closed
# Enforces: developer `impl:` commits must show a genuine red→green test transition per CC-06.3.
#           Replays the language-config test command at HEAD~ (must fail) and HEAD (must pass)
#           via scratch worktrees; blocks the next step when probe-red passes or probe-green fails.
# Reads context from: hook payload JSON at $HOOK_PAYLOAD_FILE; .claude/context/language-config.md;
#                     scratch worktrees created under .claude/context/.tdd-verify/<uid8>/
# Writes side-effects to: .claude/context/.tdd-verify/cache.json (verification cache) +
#                         transient scratch worktrees (created and removed by the Python backer)
#
# Created by: dev-workflow-plan.md [M-20] [IMPL-20-01]
# Reason: M-20 / RAG-31 — TDD outcome enforcement.
# CC conventions applied: CC-03.4 (wrapper template), CC-03.8 (header block), CC-03.2 (fail-closed).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_hook-lib.sh"

if ! hook_in_workspace; then
    exit 0
fi

hook_init || exit 0

exec "$(hook_python)" "$DIR/_tdd_red_verify.py" "$HOOK_PAYLOAD_FILE"
