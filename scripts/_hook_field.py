#!/usr/bin/env python3
"""Extract a dotted-path field from a JSON payload file.

Usage:
    _hook_field.py <payload-file> <dotted.path>

- Lists of content blocks (e.g. tool_response) are joined as text content
  separated by newlines.
- Missing paths print an empty string and exit 0.
- Non-string scalars print str(value); dicts/non-content-block lists print
  json.dumps(value).
"""
from __future__ import annotations

import json
import sys


def _join_text_blocks(items):
    parts = []
    is_content_block_list = all(
        isinstance(it, dict) and "type" in it for it in items
    ) if items else False
    if not is_content_block_list:
        return None
    for it in items:
        if it.get("type") == "text":
            parts.append(it.get("text", ""))
    return "\n".join(parts)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: _hook_field.py <payload-file> <dotted.path>", file=sys.stderr)
        return 64
    payload_path, dotted = sys.argv[1], sys.argv[2]
    try:
        with open(payload_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return 0  # missing/invalid payload prints empty string

    val = data
    for part in dotted.split("."):
        if isinstance(val, dict):
            val = val.get(part, "")
        else:
            val = ""
            break

    if isinstance(val, list):
        joined = _join_text_blocks(val)
        if joined is not None:
            sys.stdout.write(joined)
        else:
            sys.stdout.write(json.dumps(val))
    elif isinstance(val, dict):
        sys.stdout.write(json.dumps(val))
    elif val is None:
        pass
    elif isinstance(val, bool):
        sys.stdout.write("true" if val else "false")
    else:
        sys.stdout.write(str(val))
    return 0


if __name__ == "__main__":
    sys.exit(main())
