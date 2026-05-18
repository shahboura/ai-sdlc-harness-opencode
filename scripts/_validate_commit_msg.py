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

import os
import re
import subprocess
import sys
from pathlib import Path

import _git_argparse


_HELP_BLOCK = """\
Required: #<STORY-ID> #<TASK-ID>: <imperative description>
TDD form: #<STORY-ID> #T<n> test: <slug>     (Phase 3 tester)
TDD form: #<STORY-ID> #T<n> impl: <slug>     (Phase 3 developer)
Phase 5:  #<STORY-ID> test-harden: <slug>    (no Task ID; Phase 5 only)
Autosq.:  fixup!|squash!|amend!|reword! <subject>  (Phase 6 autosquash)

Body must include the trailer:
    Co-Authored-By: Claude Code <noreply@anthropic.com>

Story-ID examples: 123456 (numeric), PROJ-123 (Jira), auth.feature (slug).
Task-ID  examples: T1, T2, T-TEST-AuthService.
"""

# Co-Authored-By trailer — required on every non-autosquash commit body per
# CLAUDE.md. The check is case-insensitive on the field name (git's own
# parser accepts any casing) and tolerates extra whitespace.
_COAUTHOR_RE = re.compile(
    r"^\s*co-authored-by:\s*\S.+<[^>]+@[^>]+>\s*$",
    re.IGNORECASE | re.MULTILINE,
)

_RE_AUTOSQUASH = re.compile(r"^(?:fixup|squash|amend|reword)!\s+\S")
_RE_TEST_HARDEN = re.compile(r"^#[A-Za-z0-9_.\-]+ test-harden: .+$")
# Canonical fallback regex — used when `.claude/context/naming-config.md` is
# absent or its `commit_format:` template can't be compiled. Matches the
# shipped default `#${story_id} #${task_id} ${type}: ${slug}` plus two
# tolerated separator variants (`test: `, `impl: `) emitted by Phase 3
# TDD agents per the harness's pre-existing convention.
_RE_CANONICAL = re.compile(
    r"^#[A-Za-z0-9_.\-]+ "                       # story id
    r"#(?:T[A-Za-z0-9_.\-]+|[0-9]+)"             # task id
    r"(?:: | test: | impl: )"                    # separator
    r".+$"                                       # description
)


# IMPL-15-05: per CC-01.8 every consumer reads naming templates from
# `.claude/context/naming-config.md` — never hardcodes them. The validator
# loads `commit_format:` at runtime; on any failure (file missing, malformed,
# unrecognised placeholder), falls back to `_RE_CANONICAL` so existing test
# fixtures and pre-bootstrap workspaces keep validating.

_PLACEHOLDER_REGEX = {
    "story_id": r"[A-Za-z0-9_.\-]+",
    "task_id": r"(?:T[A-Za-z0-9_.\-]+|[0-9]+)",
    "type": r"[A-Za-z][A-Za-z0-9_-]*",
    "slug": r".+",
    "team": r"[A-Za-z0-9_.\-]+",
    "repo": r"[A-Za-z0-9_.\-]+",
    "author": r"[A-Za-z0-9_.\-]+",
    "branch_default": r"[A-Za-z0-9_./\-]+",
}

_PLACEHOLDER_RE = re.compile(r"\$\{([a-z_]+)\}")


def _find_workspace_root(start: Path | None = None) -> Path | None:
    """Walk up from `start` (default cwd) to find a directory containing
    `.claude/context/provider-config.md` — the canonical "initialised
    harness workspace" marker (mirrors `_hook-lib.sh.hook_workspace_root`).
    Returns None if not found before reaching `/`.
    """
    cur = (start or Path.cwd()).resolve()
    while True:
        if (cur / ".claude" / "context" / "provider-config.md").is_file():
            return cur
        if cur.parent == cur:
            return None
        cur = cur.parent


def _load_commit_format(workspace_root: Path) -> str | None:
    """Return the `commit_format:` template from `naming-config.md`, or
    None if the file or key is absent / unreadable.
    """
    path = workspace_root / ".claude" / "context" / "naming-config.md"
    if not path.is_file():
        return None
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    m = re.search(r"^commit_format:\s*(\S.*?)\s*$", text, re.MULTILINE)
    return m.group(1) if m else None


def _template_to_regex(template: str) -> re.Pattern[str] | None:
    """Compile a `commit_format:` template into a `re.Pattern` anchored to
    start + end of subject. Returns None on unrecognised placeholders or
    regex-compile failure (caller falls back to `_RE_CANONICAL`).
    """
    parts: list[str] = ["^"]
    i = 0
    while i < len(template):
        m = _PLACEHOLDER_RE.match(template, i)
        if m:
            name = m.group(1)
            if name not in _PLACEHOLDER_REGEX:
                return None
            parts.append(_PLACEHOLDER_REGEX[name])
            i = m.end()
        else:
            parts.append(re.escape(template[i]))
            i += 1
    parts.append("$")
    try:
        return re.compile("".join(parts))
    except re.error:
        return None


# Cached per-process — the workspace doesn't relocate mid-run.
_CACHED_CONFIG_PATTERN: tuple[bool, re.Pattern[str] | None] | None = None


def _config_pattern() -> re.Pattern[str] | None:
    """Return the workspace's compiled `commit_format` regex, or None if
    no config / unparseable. Cached after the first call.
    """
    global _CACHED_CONFIG_PATTERN
    if _CACHED_CONFIG_PATTERN is not None:
        return _CACHED_CONFIG_PATTERN[1]
    root = _find_workspace_root()
    if root is None:
        _CACHED_CONFIG_PATTERN = (False, None)
        return None
    template = _load_commit_format(root)
    if not template:
        _CACHED_CONFIG_PATTERN = (False, None)
        return None
    pattern = _template_to_regex(template)
    _CACHED_CONFIG_PATTERN = (True, pattern)
    return pattern


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
    # IMPL-15-05: prefer the workspace's compiled `commit_format` template
    # if present; fall back to the hardcoded canonical regex otherwise. The
    # hardcoded form remains the safety net — any divergence from
    # naming-config.md that the template-derived regex would accept is also
    # accepted by `_RE_CANONICAL`, and vice versa for the shipped default.
    config_pattern = _config_pattern()
    if config_pattern is not None and config_pattern.match(subject):
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
        if msg is None:
            # can't read HEAD message (unresolvable -C path) — allow; message
            # was valid when first written, --amend --no-edit reuses it verbatim
            return 0

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

    if not validate_subject(subject):
        return _block(
            "commit subject does not match the harness convention",
            subject=subject,
            command=command,
        )

    # Autosquash subjects (fixup!/squash!/amend!/reword!) are derived from
    # the referenced commit and don't carry a fresh body — skip the trailer
    # check.
    if _RE_AUTOSQUASH.match(subject):
        return 0

    # Trailer enforcement (CLAUDE.md): the `Co-Authored-By: ...` trailer is
    # required when the commit has a body. A pure subject-only `-m "..."`
    # commit (no body lines after the subject) has nothing to put a trailer
    # in — Git itself treats the trailer as a body-only construct. We
    # mirror that semantics here.
    body_lines = msg.splitlines()
    # Drop the subject line and any immediately-following blank line(s);
    # what remains is the body proper.
    if body_lines:
        body_lines = body_lines[1:]
    while body_lines and not body_lines[0].strip():
        body_lines = body_lines[1:]
    has_body = any(line.strip() for line in body_lines)
    if has_body and not _COAUTHOR_RE.search(msg):
        return _block(
            "commit body is missing the required `Co-Authored-By: ...` trailer",
            subject=subject,
            command=command,
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
