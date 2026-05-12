#!/usr/bin/env python3
"""Block Write/Edit/MultiEdit/NotebookEdit operations targeting sensitive
file patterns (`.env*`, `*.pem`, `id_rsa*`, `*.tfstate*`, etc.).

The Bash side of the same protection lives in `bash-write-guard.sh` (rule 2);
both guards share `_sensitive_patterns.py` so the deny-list stays in sync.

Reads the hook payload file path from argv[1].

Exit 0 = allow, Exit 2 = block.
"""
from __future__ import annotations

import json
import sys

from _sensitive_patterns import matches_sensitive


_FILE_PATH_KEYS = {
    "Write": "file_path",
    "Edit": "file_path",
    "MultiEdit": "file_path",
    "NotebookEdit": "notebook_path",
}


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    try:
        with open(sys.argv[1], "r", encoding="utf-8") as f:
            payload = json.load(f)
    except (OSError, json.JSONDecodeError):
        return 0

    tool_name = payload.get("tool_name", "")
    path_key = _FILE_PATH_KEYS.get(tool_name)
    if not path_key:
        return 0

    tool_input = payload.get("tool_input") or {}
    file_path = tool_input.get(path_key, "")
    # NotebookEdit historically also used `file_path`; check both.
    if not file_path and tool_name == "NotebookEdit":
        file_path = tool_input.get("file_path", "")
    if not file_path:
        return 0

    if not matches_sensitive(file_path):
        return 0

    print(
        f"sensitive-file-guard: refusing to {tool_name} a sensitive file: {file_path}",
        file=sys.stderr,
    )
    print(
        "Credentials, keys, secrets, and infra state must never be committed.",
        file=sys.stderr,
    )
    print(
        "If this write is intentional, place the file outside the repo or",
        file=sys.stderr,
    )
    print(
        "use the project's secret manager — not via an agent edit.",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
