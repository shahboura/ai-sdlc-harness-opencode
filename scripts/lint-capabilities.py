#!/usr/bin/env python3
"""Lint provider-adapter capability declarations.

For every adapter in the allow-list, verify the relevant adapter file contains a
`## Capabilities` section and that every in-scope capability appears in the table
with a status marker (✅, 🟡, or ❌). A capability without a marker is treated as
missing.

Scope: GitHub-only until other adapters are swept (WS-3 follow-up). Extending the
ALLOW_LIST when a provider is migrated is the only change needed to enforce it.

Exits 0 on success; non-zero with a list of failures on any violation.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROVIDERS_DIR = REPO_ROOT / "skills" / "providers"

WORK_ITEM_CAPS = [
    "work_item.fetch",
    "work_item.list_comments",
    "work_item.add_comment",
    "work_item.list_changelog",
    "work_item.list_children",
    "work_item.list_attachments",
    "work_item.transition_state",
    "work_item.search",
]
PR_CAPS = [
    "pr.create",
    "pr.find_for_branch",
    "pr.link_work_item",
    "pr.set_draft",
]
PR_COMMENT_CAPS = [
    "pr.list_review_comments",
    "pr.reply_to_review_comment",
]

REQUIRED_CAPS = {
    "work_item.fetch",
    "pr.create",
    "pr.list_review_comments",
    "pr.reply_to_review_comment",
}

# Map an adapter file (relative to a provider directory) to the capability set
# it must declare. Note that GitLab uses `merge-requests.md` instead of
# `pull-requests.md` (mirroring its MR terminology) — the lint accepts either
# filename for the PR capability set via the per-provider scope below.
# `pr-comments.md` is the canonical name for Phase 7 primitives across all
# providers regardless of PR/MR terminology.
ADAPTER_SCOPE = {
    "work-items.md": WORK_ITEM_CAPS,
    "pull-requests.md": PR_CAPS,
    "merge-requests.md": PR_CAPS,
    "pr-comments.md": PR_COMMENT_CAPS,
}

# Allow-list of providers under capability lint. Per-provider scope lists the
# adapter files we expect to find for that provider; missing files are flagged
# by the lint. Providers absent from this map are not yet swept and the lint
# does not enforce declarations on them.
ALLOW_LIST = {
    "ado":      ["work-items.md", "pull-requests.md",  "pr-comments.md"],
    "github":   ["work-items.md", "pull-requests.md",  "pr-comments.md"],
    "gh-cli":   [                 "pull-requests.md",  "pr-comments.md"],
    "gitlab":   ["work-items.md", "merge-requests.md", "pr-comments.md"],
    "glab-cli": [                 "merge-requests.md", "pr-comments.md"],
}

STATUS_MARKERS = ("✅", "🟡", "❌")
CAPABILITIES_HEADING_RE = re.compile(r"^##\s+Capabilities\b", re.MULTILINE)


def find_capabilities_section(text: str) -> str | None:
    """Return the body of the first `## Capabilities` section, or None."""
    m = CAPABILITIES_HEADING_RE.search(text)
    if not m:
        return None
    start = m.end()
    next_heading = re.search(r"^##\s+", text[start:], re.MULTILINE)
    end = start + next_heading.start() if next_heading else len(text)
    return text[start:end]


def cap_has_status(section: str, cap: str) -> tuple[bool, str | None]:
    """Return (declared, status) where status is the marker or None.

    A capability is "declared" when a line in the section contains the
    capability name (with or without backticks) AND one of the status
    markers. Same line — multi-line table rows are not split.
    """
    # Match the capability in any quoting form: bare or backticked.
    cap_re = re.compile(rf"[`\s|]{re.escape(cap)}[`\s|]")
    for line in section.splitlines():
        if cap_re.search(f" {line} "):
            for marker in STATUS_MARKERS:
                if marker in line:
                    return True, marker
            return True, None
    return False, None


def lint_adapter(provider: str, filename: str) -> list[str]:
    """Lint one adapter file. Return a list of failure messages."""
    path = PROVIDERS_DIR / provider / filename
    failures: list[str] = []

    if not path.exists():
        failures.append(f"{provider}/{filename}: file missing")
        return failures

    text = path.read_text(encoding="utf-8")
    section = find_capabilities_section(text)
    if section is None:
        failures.append(f"{provider}/{filename}: no `## Capabilities` section")
        return failures

    for cap in ADAPTER_SCOPE[filename]:
        declared, status = cap_has_status(section, cap)
        if not declared:
            failures.append(
                f"{provider}/{filename}: capability `{cap}` not declared"
            )
        elif status is None:
            failures.append(
                f"{provider}/{filename}: capability `{cap}` listed without a status marker (✅/🟡/❌)"
            )
        elif cap in REQUIRED_CAPS and status != "✅":
            failures.append(
                f"{provider}/{filename}: required capability `{cap}` declared "
                f"`{status}` — must be ✅ for the provider to be usable"
            )

    return failures


def main() -> int:
    all_failures: list[str] = []
    for provider, files in ALLOW_LIST.items():
        for filename in files:
            all_failures.extend(lint_adapter(provider, filename))

    if all_failures:
        print("Capability lint FAILED:", file=sys.stderr)
        for msg in all_failures:
            print(f"  - {msg}", file=sys.stderr)
        return 1

    total = sum(len(files) for files in ALLOW_LIST.values())
    print(f"Capability lint OK ({total} adapter file(s) checked).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
