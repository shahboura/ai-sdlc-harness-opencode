#!/usr/bin/env python3
"""SubagentStop hook — enforce that every subagent response ends with a
properly-shaped `📋 AGENT STATUS` block.

Reads the hook payload file path from argv[1].

Schema: `agents/shared/status-schema.md`. This hook enforces the universal
floor only. Mode-specific field enforcement lives in
`tests/skills/status-schema.test.sh` (doc-grep regression on every agent's
status-block example) — the hook does not try to reproduce that logic
because it cannot reliably distinguish modes from one block at runtime.

Universal floor (enforced):
  - `📋 AGENT STATUS` phrase appears in the response's final tail window.
  - The block contains `Agent: <recognized name>` (planner | developer |
    tester | reviewer).
  - The block contains one of `Outcome:` or `Verdict:` with a **non-empty**
    value.
  - The block contains `Next action:` with a non-empty value.

Fail policy: fail-CLOSED when a response was extracted but the floor isn't
met; fail-OPEN when no response text can be located in the payload (logs a
warning so the gap is investigatable).

Exit 0 = allow, Exit 2 = block.
"""
from __future__ import annotations

import json
import re
import sys
from typing import Any


_REQUIRED_PHRASE = "📋 AGENT STATUS"
_KNOWN_AGENTS = ("planner", "developer", "tester", "reviewer")

# The tail window scales with response length: at least 10 lines so a typical
# status block (header + ~8 fields + short prose preamble) fits in a short
# response, at most 50 so very long responses don't get a slack window.
# Between the bounds it tracks the last ~quarter of the response.
_TAIL_LINES_MIN = 10
_TAIL_LINES_MAX = 50


def _tail_window(line_count: int) -> int:
    return min(_TAIL_LINES_MAX, max(_TAIL_LINES_MIN, line_count // 4))


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


def _field_value(block: str, field: str) -> str | None:
    """Extract a `<field>: <value>` from the block (multiline-safe).

    Returns the trimmed value, or None if the field is absent. An empty
    value (`field:` with nothing after the colon) returns "" — callers
    can distinguish missing vs empty by checking `is None` vs falsy.

    Uses `[ \t]*` (not `\s*`) for the whitespace classes so the match
    cannot cross a newline. With `\s*` and `re.MULTILINE`, an empty
    `Outcome:` would swallow the following line's value because `\s*`
    matched the newline.
    """
    pattern = re.compile(
        rf"^[ \t\-*]*{re.escape(field)}:[ \t]*([^\n]*)",
        re.MULTILINE,
    )
    m = pattern.search(block)
    if m is None:
        return None
    return m.group(1).rstrip()


def _validate(response: str) -> tuple[bool, str]:
    """Return (ok, reason). reason is empty when ok=True."""
    if _REQUIRED_PHRASE not in response:
        return False, f'response does not contain the literal phrase "{_REQUIRED_PHRASE}"'

    lines = response.splitlines()
    tail_size = _tail_window(len(lines))
    tail = "\n".join(lines[-tail_size:])
    if _REQUIRED_PHRASE not in tail:
        return (
            False,
            f'the "{_REQUIRED_PHRASE}" phrase appears, but not in the response\'s '
            f'final {tail_size} lines (of {len(lines)} total) — the block must end '
            f'the response.',
        )

    block_start = response.rfind(_REQUIRED_PHRASE)
    block = response[block_start:]

    # `Agent:` with a recognized name.
    agent_val = _field_value(block, "Agent")
    if agent_val is None:
        return False, 'the block has no `Agent:` field. Add one of: planner | developer | tester | reviewer.'
    if agent_val.strip() not in _KNOWN_AGENTS:
        return (
            False,
            f'`Agent:` value `{agent_val.strip() or "(empty)"}` is not recognized. '
            f'Expected one of: {" | ".join(_KNOWN_AGENTS)}.',
        )

    # Outcome OR Verdict with a non-empty value.
    outcome_val = _field_value(block, "Outcome")
    verdict_val = _field_value(block, "Verdict")
    has_outcome = outcome_val is not None and outcome_val.strip() != ""
    has_verdict = verdict_val is not None and verdict_val.strip() != ""
    if not (has_outcome or has_verdict):
        # Distinguish "field absent" from "field present but empty" so the
        # error message is precise.
        outcome_state = "absent" if outcome_val is None else "empty"
        verdict_state = "absent" if verdict_val is None else "empty"
        return (
            False,
            f'the block needs at least one of `Outcome:` / `Verdict:` with a '
            f'non-empty value. Currently: Outcome={outcome_state}, Verdict={verdict_state}.',
        )

    # Next action with a non-empty value.
    next_action_val = _field_value(block, "Next action")
    if next_action_val is None or next_action_val.strip() == "":
        return (
            False,
            'the block needs a `Next action:` field with a non-empty value '
            "(the orchestrator's decision matrix routes on this).",
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
        "    - Agent: planner | developer | tester | reviewer\n"
        "    - Outcome: SUCCESS | PARTIAL | FAILED | BLOCKED   (or Verdict: for reviewers)\n"
        "    - Next action: <one-line description>\n"
        "    (additional fields per agents/shared/status-schema.md)\n",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
