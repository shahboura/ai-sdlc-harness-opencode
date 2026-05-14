#!/usr/bin/env python3
"""Validate a git commit-message hook payload against the harness convention.

Reads the full Bash command as argv[1] (the bash entry already pulled
`tool_input.command` from the payload).

Exit codes:
    0   allow (not a `git commit`, or subject matches convention)
    2   block (subject does not match convention, or parser couldn't tell)

Fail policy: fail CLOSED. If the parser cannot extract a message and the
command is `--allow-empty-message`, allow; otherwise block.
"""
from __future__ import annotations

import re
import subprocess
import sys

import _git_argparse


_HELP_BLOCK = """\
Required: #<STORY-ID> #<TASK-ID>: <imperative description>
TDD form: #<STORY-ID> #T<n> test: <slug>     (Phase 3 tester)
TDD form: #<STORY-ID> #T<n> impl: <slug>     (Phase 3 developer)
Phase 5:  #<STORY-ID> test-harden: <slug>    (no Task ID; Phase 5 only)
Autosq.:  fixup!|squash!|amend!|reword! <subject>  (Phase 6 autosquash)

Story-ID examples: 123456 (numeric), PROJ-123 (Jira), auth.feature (slug).
Task-ID  examples: T1, T2, T-TEST-AuthService.
"""

_RE_AUTOSQUASH = re.compile(r"^(?:fixup|squash|amend|reword)!\s+\S")
_RE_TEST_HARDEN = re.compile(r"^#[A-Za-z0-9_.\-]+ test-harden: .+$")
_RE_CANONICAL = re.compile(
    r"^#[A-Za-z0-9_.\-]+ "                       # story id
    r"#(?:T[A-Za-z0-9_.\-]+|[0-9]+)"             # task id
    r"(?:: | test: | impl: )"                    # separator
    r".+$"                                       # description
)


def _block(reason: str, subject: str | None = None, command: str | None = None) -> int:
    print(f"validate-commit-msg: {reason}", file=sys.stderr)
    print("", file=sys.stderr)
    print(_HELP_BLOCK, file=sys.stderr)
    if subject is not None:
        print(f"Got subject: {subject}", file=sys.stderr)
    if command is not None:
        print(f"Command:     {command}", file=sys.stderr)
    return 2


def _read_amend_message(git_c: str | None) -> str | None:
    """Re-read the HEAD commit message that --amend will reuse."""
    args = ["git"]
    if git_c:
        args += ["-C", git_c]
    args += ["log", "-1", "--format=%B"]
    try:
        result = subprocess.run(
            args, capture_output=True, text=True, timeout=5, check=False
        )
        if result.returncode != 0:
            return None
        return result.stdout
    except (OSError, subprocess.TimeoutExpired):
        return None


def _read_file_message(path: str) -> str | None:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def _first_non_blank_line(message: str) -> str | None:
    for line in message.splitlines():
        if line.strip():
            return line.strip()
    return None


def validate_subject(subject: str) -> bool:
    if _RE_AUTOSQUASH.match(subject):
        return True
    if _RE_TEST_HARDEN.match(subject):
        return True
    if _RE_CANONICAL.match(subject):
        return True
    return False


def main() -> int:
    if len(sys.argv) < 2:
        return 0  # nothing to validate
    command = sys.argv[1]
    parsed = _git_argparse.parse(command)

    if not parsed.get("is_git_commit"):
        return 0

    if parsed.get("parse_error"):
        return _block(
            "could not parse the git-commit command (refusing to commit)",
            command=command,
        )

    # `git commit --fixup <ref>` / `--squash <ref>` / `--reword <ref>` derive
    # the subject from the referenced commit. The referenced commit was
    # validated when it was created, and the subsequent autosquash rebase
    # collapses the fixup. Allow.
    if parsed.get("autosquash") and not parsed.get("messages"):
        return 0

    msg: str | None = parsed.get("extracted_message")
    source = parsed.get("extracted_message_source")

    if msg is None and source == "amend":
        msg = _read_amend_message(parsed.get("git_C"))
        source = "amend"

    if msg is None and source == "F" and parsed.get("file_messages"):
        msg = _read_file_message(parsed["file_messages"][0])
        source = "F"

    if (msg is None or msg.strip() == "") and parsed.get("allow_empty_message"):
        return 0

    if msg is None or msg.strip() == "":
        return _block(
            "could not extract a commit message (refusing to commit)",
            command=command,
        )

    subject = _first_non_blank_line(msg)
    if subject is None:
        return _block("commit message has no non-blank subject line", command=command)

    if validate_subject(subject):
        return 0

    return _block(
        "commit subject does not match the harness convention",
        subject=subject,
        command=command,
    )


if __name__ == "__main__":
    sys.exit(main())
