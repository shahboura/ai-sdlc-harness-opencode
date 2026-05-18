"""Shared status-block field extraction.

> Owner: cross-cutting
> Version: 1.0

Created by: dev-workflow-plan.md [M-01] [IMPL-01-09]
Reason: Foundational shared helper — extracts the `Field: Value` parsing pattern
that appeared inline in both `_agent_status_check.py` and `_tracker_update_reminder.py`.
CC conventions applied: CC-04.2, CC-04.3 (Python `from` form), CC-04.4 (owner = cross-cutting).

Exports:
    extract_field_from_block(block, name) -> str
    extract_field_value(block, name) -> str | None
    extract_status_block(text) -> str | None
"""
from __future__ import annotations

import re
from typing import Optional


_STATUS_BLOCK_HEADER_RE = re.compile(r"(?:📋\s*)?AGENT STATUS\b[^\n]*\n")
_NEXT_HEADING_RE = re.compile(r"\n#{1,2}\s")


def extract_status_block(text: str) -> Optional[str]:
    """Locate the `📋 AGENT STATUS` block in `text` and return it (including the
    header line) up to the next H1/H2 heading or end-of-text.

    Returns None when no header is found.

    The extent rule (header → next H1/H2 or EOF) matches the pre-existing
    behaviour in `_tracker_update_reminder.py` — stopping at `\\n\\n` lost
    multi-paragraph fields and is intentionally not used.
    """
    m = _STATUS_BLOCK_HEADER_RE.search(text)
    if not m:
        return None
    start = m.start()
    rest = text[m.end():]
    end_m = _NEXT_HEADING_RE.search(rest)
    if end_m:
        return text[start : m.end() + end_m.start()]
    return text[start:]


def extract_field_from_block(block: str, name: str) -> str:
    """Return the value of `name:` in `block` (single-line value), or empty
    string when the field is absent.

    Matching is multi-line, anchored at the start of a line; whitespace around
    both the key and the value is stripped. Field names are matched literally —
    the caller is responsible for case if the schema is case-sensitive.

    Empty-vs-missing is collapsed (both → ""). For callers that need the
    distinction — e.g. status-block validation — use `extract_field_value`.
    """
    pattern = re.compile(rf"^\s*{re.escape(name)}\s*:\s*(.+?)\s*$", re.MULTILINE)
    m = pattern.search(block)
    return m.group(1) if m else ""


def extract_field_value(block: str, name: str) -> Optional[str]:
    """Like `extract_field_from_block` but distinguishes missing (None) from
    empty ("") values.

    Uses `[ \\t]*` (not `\\s*`) around the colon so the match cannot cross a
    newline. With `\\s*` and `re.MULTILINE`, an empty `Outcome:` would swallow
    the following line's value because `\\s*` matched the newline.
    """
    pattern = re.compile(
        rf"^[ \t\-*]*{re.escape(name)}:[ \t]*([^\n]*)",
        re.MULTILINE,
    )
    m = pattern.search(block)
    if m is None:
        return None
    return m.group(1).rstrip()
