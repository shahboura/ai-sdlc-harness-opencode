#!/usr/bin/env bash
# CC03-hook-policy-declared.convention-check.test.sh — TEST-72
#
# Per cc-conventions.md CC-03.2, every hook script (Bash wrapper) MUST
# declare its fail-closed vs fail-open policy in the header block. A hook
# whose policy is undeclared can drift silently — a contributor edits the
# behaviour without updating the contract, and reviewers have no anchor
# to catch the mismatch.
#
# This check scans every `scripts/*.sh` that's registered in
# `hooks/hooks.json` and asserts the file contains a `# policy:` line in
# its top header block. Bash-only files NOT registered as hooks are
# excluded (the rule scopes to hooks specifically, not every shell
# script in the repo).
#
# Created by: dev-workflow-plan.md [M-13] [IMPL-13-02]
# Maps to: TEST-72 (CC-03.2 policy declaration).
# CC conventions applied: CC-03.2, CC-04.5, CC-06.2.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import json
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
hooks_json = repo / "hooks" / "hooks.json"

if not hooks_json.is_file():
    print(f"[CC-03.2] hooks/hooks.json missing — cannot enforce policy declaration", file=sys.stderr)
    sys.exit(2)

# Discover every script registered as a hook.
try:
    cfg = json.loads(hooks_json.read_text(encoding="utf-8"))
except json.JSONDecodeError as e:
    print(f"[CC-03.2] hooks.json invalid: {e}", file=sys.stderr)
    sys.exit(2)

REGISTERED: set[Path] = set()
_PLUGIN_ROOT_TOKEN = "${CLAUDE_PLUGIN_ROOT}/"

def _walk(node):
    if isinstance(node, dict):
        cmd = node.get("command")
        if isinstance(cmd, str):
            if cmd.startswith(_PLUGIN_ROOT_TOKEN):
                rel = cmd[len(_PLUGIN_ROOT_TOKEN):]
                REGISTERED.add(repo / rel)
        for v in node.values():
            _walk(v)
    elif isinstance(node, list):
        for v in node:
            _walk(v)

_walk(cfg)

if not REGISTERED:
    print(f"[CC-03.2] no hook scripts registered in hooks.json — nothing to check", file=sys.stderr)
    sys.exit(0)

# Header-block scan: read the first ~30 lines of each registered script
# and assert a `# policy:` line (case-insensitive on the policy keyword)
# is present. The actual policy text isn't validated here — the rule is
# that the contract is declared, full stop.
_POLICY_LINE_RE = re.compile(r"^\s*#\s*policy:\s*\S+", re.IGNORECASE | re.MULTILINE)
HEADER_LINES = 30

violations: list[str] = []
checked = 0
for path in sorted(REGISTERED):
    if not path.is_file():
        violations.append(f"{path.relative_to(repo)}: registered in hooks.json but file does not exist")
        continue
    checked += 1
    try:
        content = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        violations.append(f"{path.relative_to(repo)}: unreadable ({e})")
        continue
    head = "\n".join(content.splitlines()[:HEADER_LINES])
    if not _POLICY_LINE_RE.search(head):
        violations.append(
            f"{path.relative_to(repo)}: header block (first {HEADER_LINES} lines) "
            f"missing `# policy:` declaration (CC-03.2)"
        )

print(f"CC-03.2 hook-policy declaration: scanned {checked} registered hook script(s)")
for v in violations:
    print(f"  ✗ {v}", file=sys.stderr)
if not violations:
    print("  all hooks declare their policy ✓")

sys.exit(1 if violations else 0)
PY
