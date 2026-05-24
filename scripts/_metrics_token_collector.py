#!/usr/bin/env python3
"""_metrics_token_collector.py — Token-usage aggregator for the Stop hook.

Called by metrics-token-collector.sh at session close (Stop event).
Parses the Claude Code transcript JSONL at --transcript to sum token counts,
then appends one line to ai/<id>/.token-log.jsonl in the workspace.

Per ADR-002 Path-A: transcript_path (Stop payload) is the data source because
PostToolUse hook payloads do not expose per-invocation token usage (US-E02-007 spike).

Null-safety (CC-02.4.2): missing transcript, unparseable lines, or absent usage
fields all result in null (empty) token values — the line is still written so
the session is recorded and downstream tools can detect "tokens unavailable".

Created by: dev-workflow-plan.md [M-25] [IMPL-25-04]
CC conventions applied: CC-02.4.2 (null-safe), ADR-002 (orchestrator-capture).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Optional, Tuple

# ---------------------------------------------------------------------------
# Token field names in the Anthropic API response usage block
# → maps to our .token-log.jsonl column names
# ---------------------------------------------------------------------------
_USAGE_MAP = {
    "input_tokens":                 "tokens_input",
    "output_tokens":                "tokens_output",
    "cache_read_input_tokens":      "tokens_cache_read",
    "cache_creation_input_tokens":  "tokens_cache_write",
}

_NULL_TOKENS: Dict[str, Optional[int]] = {
    "tokens_input":      None,
    "tokens_output":     None,
    "tokens_cache_read": None,
    "tokens_cache_write": None,
}


# ---------------------------------------------------------------------------
# Transcript parsing
# ---------------------------------------------------------------------------

def _parse_transcript(transcript_path: str) -> Dict[str, Optional[int]]:
    """Parse transcript JSONL and return aggregated token counts.

    Returns a dict with keys tokens_input, tokens_output, tokens_cache_read,
    tokens_cache_write.  Any key that cannot be summed is returned as None.

    Transcript lines with type=="assistant" carry a message.usage block:
        {"type": "assistant", "message": {"usage": {"input_tokens": N, ...}}}

    We also handle lines where usage is at the top level (older format):
        {"type": "assistant", "usage": {"input_tokens": N, ...}}
    """
    if not transcript_path:
        return dict(_NULL_TOKENS)

    path = Path(transcript_path)
    if not path.is_file():
        return dict(_NULL_TOKENS)

    totals: Dict[str, int] = {k: 0 for k in _NULL_TOKENS}
    found_any = False

    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue

                if not isinstance(record, dict):
                    continue

                # Accept both top-level "usage" and nested "message.usage"
                usage = None
                if record.get("type") == "assistant":
                    msg = record.get("message", {})
                    if isinstance(msg, dict):
                        usage = msg.get("usage")
                    if usage is None:
                        usage = record.get("usage")

                if not isinstance(usage, dict):
                    continue

                for api_key, our_key in _USAGE_MAP.items():
                    val = usage.get(api_key)
                    if isinstance(val, (int, float)):
                        totals[our_key] += int(val)
                        found_any = True

    except (OSError, UnicodeDecodeError):
        return dict(_NULL_TOKENS)

    if not found_any:
        return dict(_NULL_TOKENS)

    return {k: v for k, v in totals.items()}


# ---------------------------------------------------------------------------
# Workflow directory resolution
# ---------------------------------------------------------------------------

def _find_active_workflow_dir(workspace: Path) -> Optional[Path]:
    """Return the most recently modified per-workflow directory under ai/.

    Heuristic: find all ai/<date>-<id>/tracker.md files, return the parent
    of whichever was most recently modified.  Returns None if ai/ is absent
    or no tracker is found.
    """
    ai_root = workspace / "ai"
    if not ai_root.is_dir():
        return None

    candidates = []
    for tracker in ai_root.glob("*/tracker.md"):
        try:
            mtime = tracker.stat().st_mtime
            candidates.append((mtime, tracker.parent))
        except OSError:
            continue
    # Also accept archived trackers
    for tracker in ai_root.glob("*/tracker.archived.md"):
        try:
            mtime = tracker.stat().st_mtime
            candidates.append((mtime, tracker.parent))
        except OSError:
            continue

    if not candidates:
        return None

    candidates.sort(key=lambda x: x[0], reverse=True)
    return candidates[0][1]


# ---------------------------------------------------------------------------
# JSONL writer
# ---------------------------------------------------------------------------

def _append_token_log(
    workflow_dir: Path,
    session_id: str,
    tokens: Dict[str, Optional[int]],
    generated_at: str,
) -> None:
    """Append one JSONL line to ai/<id>/.token-log.jsonl."""
    log_path = workflow_dir / ".token-log.jsonl"
    # Derive story_id from directory name: <YYYY-MM-DD>-<story-id>
    dir_name = workflow_dir.name
    parts = dir_name.split("-", 3)  # YYYY-MM-DD-<story-id>
    story_id = parts[3] if len(parts) >= 4 else dir_name

    record = {
        "ts": generated_at,
        "story_id": story_id,
        "session_id": session_id or "",
        **tokens,
    }

    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\n")
    except OSError:
        pass  # fail-open: never block the workflow


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Aggregate session token usage from transcript and write to .token-log.jsonl"
    )
    parser.add_argument("--workspace", required=True, help="Workspace root directory")
    parser.add_argument("--transcript", default="", help="Path to transcript JSONL (from Stop payload)")
    parser.add_argument("--session-id", default="", help="Session ID (from Stop payload)")
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])

    workspace = Path(args.workspace).resolve()
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    tokens = _parse_transcript(args.transcript)

    workflow_dir = _find_active_workflow_dir(workspace)
    if workflow_dir is None:
        return 0  # no active workflow — nothing to write

    _append_token_log(workflow_dir, args.session_id, tokens, generated_at)
    return 0


if __name__ == "__main__":
    sys.exit(main())
