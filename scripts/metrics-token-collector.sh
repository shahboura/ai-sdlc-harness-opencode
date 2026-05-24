#!/usr/bin/env bash
# Hook: metrics-token-collector
# Event: Stop
# Matcher: ""
# Policy: fail-open
# Enforces: captures per-session token usage from transcript; writes ai/<id>/.token-log.jsonl
# Reads context from: Stop payload (transcript_path, session_id), workspace ai/ directory
# Writes side-effects to: ai/<YYYY-MM-DD>-<work-item-id>/.token-log.jsonl
# ---
# name: metrics-token-collector
# event: Stop
# matcher: ""
# scope: workspace
# blocking: false
# policy: fail-OPEN (advisory)
# description: >
#   At session close (Stop event), parses the Claude Code transcript JSONL at
#   transcript_path and aggregates per-session token usage (input, output,
#   cache_read, cache_write). Writes one line to ai/<id>/.token-log.jsonl
#   for later consumption by the metrics-collector skill (US-E02-005).
#
#   Uses Path-A mitigation from US-E02-007 spike: PostToolUse payloads do not
#   expose token data; transcript_path (Stop payload field) does.
#
#   Fail-open: if the transcript is absent or unparseable, writes a null-token
#   line and exits 0. Never blocks the workflow.
#
# Created by: dev-workflow-plan.md [M-25] [IMPL-25-04]
# CC conventions applied: CC-02.4.2 (null-safe token fields), CC-03.2 (fail-open),
#   CC-03.8 (canonical header block), ADR-002 (orchestrator-aggregated capture).
# ---
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_hook-lib.sh"

# Fail-open: any error must not block the workflow.
hook_init || exit 0

WS_ROOT="$(hook_workspace_root 2>/dev/null || true)"
if [ -z "$WS_ROOT" ]; then
    exit 0  # not in a harness workspace — nothing to do
fi

TRANSCRIPT_PATH="$(hook_field transcript_path 2>/dev/null || true)"
SESSION_ID="$(hook_field session_id 2>/dev/null || true)"

# Delegate to Python for JSONL parsing and writing.
"$(hook_python)" "$DIR/_metrics_token_collector.py" \
    --workspace "$WS_ROOT" \
    --transcript "${TRANSCRIPT_PATH:-}" \
    --session-id "${SESSION_ID:-}" \
    2>/dev/null || true   # fail-open: ignore all errors

exit 0
