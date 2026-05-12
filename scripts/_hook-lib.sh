#!/usr/bin/env bash
# _hook-lib.sh — shared primitives for ai-sdlc-harness hook scripts.
#
# Source this from a hook with:
#   DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$DIR/_hook-lib.sh"
#
# Exposes:
#   hook_python                    Echoes the resolved python binary, blocking
#                                  with exit 2 if neither python3 nor python
#                                  is available.
#   hook_init                      Reads stdin once into a temp file.
#                                  Sets HOOK_PAYLOAD_FILE. Returns non-zero
#                                  if stdin is empty.
#   hook_field <dotted-path>       Prints the field value from the JSON payload.
#                                  Lists of content blocks are joined as text.
#   hook_block <message>           Prints message to stderr and exits 2 (block).
#   hook_advise <message>          Prints message to stderr and exits 0 (advise).
#   hook_workspace_root            Walks up from cwd to find a directory
#                                  containing .claude/context/provider-config.md.
#                                  Echoes the absolute path; returns non-zero
#                                  if not found.
#   hook_in_workspace              Returns 0 if hook_workspace_root finds one.
#
# Fail-policy guidance:
#   - Parser hooks (validate-commit-msg, bash-write-guard) MUST fail closed:
#     if the parser can't make sense of the input, refuse the tool call so
#     the convention is never silently bypassed.
#   - Advisory hooks (tracker-update-reminder, tracker-metrics-guard) MUST
#     fail open: print to stderr, exit 0, never block a workflow.
#   - The script's first line of code SHOULD make its policy explicit:
#     `set -uo pipefail` plus a comment stating "fail-closed" or "fail-open".

# ─── Workspace gate ─────────────────────────────────────────────────────────
# Walks up from cwd looking for a marker file. We treat ".claude/context/
# provider-config.md" as the canonical "this is an initialised harness
# workspace" marker.
hook_workspace_root() {
    local d="${PWD}"
    while [ "$d" != "/" ] && [ -n "$d" ]; do
        if [ -f "$d/.claude/context/provider-config.md" ]; then
            printf '%s' "$d"
            return 0
        fi
        d="$(dirname "$d")"
    done
    return 1
}

hook_in_workspace() {
    hook_workspace_root >/dev/null 2>&1
}

# ─── Python probe ────────────────────────────────────────────────────────────
# Probed once at source time. If Python is missing we exit immediately in the
# parent shell, NOT from a `$(...)` subshell — otherwise `$(hook_python)`
# would swallow the exit and the parent would `exec ""` with undefined
# behaviour.
_HOOK_PYTHON=""
for _candidate in python3 python; do
    _p="$(command -v "$_candidate" 2>/dev/null || true)"
    if [ -n "$_p" ] && "$_p" --version >/dev/null 2>&1; then
        _HOOK_PYTHON="$_p"
        break
    fi
done
unset _candidate _p
if [ -z "$_HOOK_PYTHON" ]; then
    printf 'hook-lib: Python 3 is required but was not found on PATH.\n' >&2
    exit 2
fi

hook_python() {
    printf '%s' "$_HOOK_PYTHON"
}

# ─── Payload handling ───────────────────────────────────────────────────────
HOOK_PAYLOAD_FILE=""

_hook_cleanup() {
    if [ -n "$HOOK_PAYLOAD_FILE" ] && [ -f "$HOOK_PAYLOAD_FILE" ]; then
        rm -f "$HOOK_PAYLOAD_FILE"
    fi
}

hook_init() {
    HOOK_PAYLOAD_FILE="$(mktemp -t hookpayload.XXXXXX 2>/dev/null || mktemp)"
    if [ -z "$HOOK_PAYLOAD_FILE" ]; then
        return 1
    fi
    trap _hook_cleanup EXIT
    cat > "$HOOK_PAYLOAD_FILE"
    [ -s "$HOOK_PAYLOAD_FILE" ]
}

hook_field() {
    local path="$1"
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    "$(hook_python)" "$lib_dir/_hook_field.py" "$HOOK_PAYLOAD_FILE" "$path"
}

# ─── Exit helpers ────────────────────────────────────────────────────────────
hook_block() {
    printf '%s\n' "$*" >&2
    exit 2
}

hook_advise() {
    printf '%s\n' "$*" >&2
    exit 0
}
