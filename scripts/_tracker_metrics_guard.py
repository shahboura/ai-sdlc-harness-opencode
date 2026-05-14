#!/usr/bin/env python3
"""Tracker metrics guard — advisory.

Warns when timestamp values written to a tracker file do not use the full
`YYYY-MM-DD HH:MM UTC` format. Reads the hook payload file path from argv[1].

Valid formats:
    2026-04-05 14:30 UTC     full datetime, required
    --                       placeholder, allowed
    local-test               special CI value, allowed

Invalid formats (warned, never blocked):
    2026-04-05               date only — time missing
    2026-04-05T14:30         ISO 8601 T separator instead of space
    2026-04-05 14:30         missing UTC suffix

Fail policy: always exit 0 (advisory only). Print warnings to stdout so the
edit proceeds while the user still sees the hint.
"""
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone


_TRACKER_PATH_RE = re.compile(r"(^|/)ai/tasks/")
# A date-shaped token NOT immediately followed by ' HH:MM UTC'.
#
#   2026-04-05 14:30 UTC   → negative lookahead blocks → no match (valid)
#   2026-04-05             → lookahead fails → matches (incomplete)
#   2026-04-05 14:30       → lookahead fails (no UTC) → matches (missing suffix)
#   2026-04-05T14:30       → T is not \s → lookahead fails → matches (wrong sep)
_INVALID_TS_RE = re.compile(r"\d{4}-\d{2}-\d{2}(?!\s+\d{2}:\d{2}\s+UTC)")


def _is_tracker_file(path: str) -> bool:
    return bool(_TRACKER_PATH_RE.search(path))


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    try:
        with open(sys.argv[1], "r", encoding="utf-8") as f:
            payload = json.load(f)
    except (OSError, json.JSONDecodeError):
        return 0

    if payload.get("tool_name", "") != "Edit":
        return 0

    tool_input = payload.get("tool_input") or {}
    file_path = tool_input.get("file_path", "")
    if not file_path or not _is_tracker_file(file_path):
        return 0

    new_string = tool_input.get("new_string", "")
    if not isinstance(new_string, str) or not new_string:
        return 0

    match = _INVALID_TS_RE.search(new_string)
    if not match:
        return 0

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
    print(f"ADVISORY: Timestamp '{match.group(0)}' in tracker metrics may be incomplete.")
    print("  Required format:  YYYY-MM-DD HH:MM UTC")
    print(f"  Example:          {now} UTC")
    print("  Allowed values:   --  (placeholder)  |  local-test  (CI/test runs)")
    print(f"  File: {file_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
