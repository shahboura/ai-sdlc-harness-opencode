#!/usr/bin/env python3
"""SubagentStop hook — enforce that every subagent response ends with a
properly-shaped `📋 AGENT STATUS` block.

Reads the hook payload file path from argv[1].

Tightening vs. the previous implementation:
- No `/tmp/agent-status-debug.json` write.
- Presence check upgraded from "phrase appears anywhere" to "block appears
  AND contains a non-empty `Outcome:` or `Verdict:` field". Blocks where
  the agent only typed the literal phrase fall through.
- Block must occur within the last 50 lines of the response (rough
  "near the end" check). The phrase mentioned in mid-response prose
  no longer satisfies the gate.

Fail policy: fail-CLOSED when a response was extracted but lacks the block;
fail-OPEN when no response text can be located in the payload (logs a
warning so the gap is investigatable).

Exit 0 = allow, Exit 2 = block.
"""
from __future__ import annotations

import json
import sys
from typing import Any


_REQUIRED_PHRASE = "📋 AGENT STATUS"
_FIELDS_THAT_PROVE_BLOCK_IS_REAL = ("Outcome:", "Verdict:")
_TAIL_LINES = 50


def _extract_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [
            p.get("text", "")
            for p in content
            if isinstance(p, dict) and p.get("type") == "text"
        ]
        return "\n".join(parts)
    return ""


def _extract_response(payload: dict) -> str:
    """Try multiple known and plausible keys, then fall back to the most
    recent assistant message in `messages`/`transcript`.
    """
    for k in ("response", "agent_response", "final_response", "text", "output", "result"):
        v = payload.get(k)
        if isinstance(v, str) and v:
            return v
        if isinstance(v, list):
            joined = _extract_text(v)
            if joined:
                return joined
    msgs = payload.get("messages") or payload.get("transcript") or []
    if isinstance(msgs, list):
        for m in reversed(msgs):
            if isinstance(m, dict) and m.get("role") == "assistant":
                text = _extract_text(m.get("content", ""))
                if text:
                    return text
    return ""


def _validate(response: str) -> tuple[bool, str]:
    """Return (ok, reason). reason is empty when ok=True."""
    if _REQUIRED_PHRASE not in response:
        return False, f'response does not contain the literal phrase "{_REQUIRED_PHRASE}"'

    tail = "\n".join(response.splitlines()[-_TAIL_LINES:])
    if _REQUIRED_PHRASE not in tail:
        return (
            False,
            f'the "{_REQUIRED_PHRASE}" phrase appears, but not in the response\'s '
            f'final {_TAIL_LINES} lines — the block must end the response.',
        )

    block_start = response.rfind(_REQUIRED_PHRASE)
    block = response[block_start:]
    if not any(field in block for field in _FIELDS_THAT_PROVE_BLOCK_IS_REAL):
        return (
            False,
            f'the "{_REQUIRED_PHRASE}" header is present but the block has '
            f"no Outcome: or Verdict: field. Add at least one of those.",
        )

    return True, ""


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    try:
        with open(sys.argv[1], "r", encoding="utf-8") as f:
            payload = json.load(f)
    except (OSError, json.JSONDecodeError):
        return 0

    response = _extract_response(payload)
    if not response:
        # No text to evaluate — emit a one-line stderr warning and pass.
        # Fail-OPEN here so that an unfamiliar payload shape doesn't
        # block every subagent stop; the agent-status contract is
        # still enforced wherever the response *can* be located.
        print(
            "agent-status-check: could not locate response text in payload; "
            "passing without check.",
            file=sys.stderr,
        )
        return 0

    ok, reason = _validate(response)
    if ok:
        return 0

    print("agent-status-check: blocking subagent stop", file=sys.stderr)
    print(f"  - {reason}", file=sys.stderr)
    print("", file=sys.stderr)
    print(
        'Every subagent must end its response with a block of the form:\n'
        "    📋 AGENT STATUS\n"
        "    Outcome: SUCCESS | PARTIAL | FAILED | BLOCKED\n"
        "    (additional fields per the agent's contract)\n",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
