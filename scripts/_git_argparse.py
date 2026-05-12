#!/usr/bin/env python3
"""Parse a Bash command string and extract git-commit structure.

Reads the full command from stdin (the shell argv string the user is
about to run). Emits a JSON object on stdout:

    {
      "is_git_commit": bool,
      "git_C": "<path or null>",
      "amend": bool,
      "allow_empty_message": bool,
      "messages": ["..."],          # accumulated -m / --message values
      "file_messages": ["path"],    # -F / --file references (NOT read here)
      "extracted_message": "...",   # joined messages with \\n\\n (may be null)
      "extracted_message_source": "m" | "F" | "amend" | "heredoc" | null,
      "heredoc_used": bool,         # heredoc body was substituted into a -m value
      "parse_error": bool,
      "reason": "..."               # only present when parse_error is true
    }

Handles:
- `git commit ...`
- `git -C <path> commit ...`
- `git -c key=value commit ...`
- chain prefixes:  `cd X && git ...`, `(cd X; git ...)`, `X=Y git ...`
- `-m`/`--message`/`--message=`, multiple instances joined with two newlines
- `-F`/`--file`/`--file=`  (reported, not read)
- `--amend`
- `--allow-empty-message`
- heredoc bodies passed via `$(cat <<TAG ... TAG)` — body substituted into
  the matching `-m` value via a placeholder. Supports `<<TAG`, `<<'TAG'`,
  `<<"TAG"`, `<<-TAG`. Multiple heredocs are addressed by index.

Fail policy: any internal exception is treated as a parse error so the
calling hook can fail closed.
"""
from __future__ import annotations

import json
import re
import shlex
import sys


_HEREDOC_RE = re.compile(
    r"<<(-)?\s*[\"\']?(\w+)[\"\']?[^\n]*\n(.*?)\n[\t ]*\2(?:\b|$)",
    re.DOTALL,
)
_ENV_PREFIX_RE = re.compile(r"^(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)+")
_PLACEHOLDER_RE = re.compile(r"__HEREDOC_(\d+)__")


def _find_git_commit_segment(cmd: str) -> str:
    """Pick the segment of a chained command that contains 'git ... commit'.

    Splits on top-level `&&`, `||`, `;`, `|`. Conservative: no quote-aware
    splitting, so a chain operator inside a string would mis-split — but
    the result is still a string containing `git commit`, and downstream
    parsing will surface a parse_error in that pathological case.
    """
    s = cmd.strip()
    # Strip wrapping subshell `(...)`
    if s.startswith("(") and s.endswith(")"):
        s = s[1:-1].strip()
    parts = re.split(r"\s*(?:&&|\|\||;|\|)\s*", s)
    for part in parts:
        if re.search(r"\bgit\b", part) and re.search(r"\bcommit\b", part):
            return _ENV_PREFIX_RE.sub("", part.strip())
    return s


def _replace_heredocs(cmd: str) -> tuple[str, list[str]]:
    """Replace heredoc blocks with placeholder tokens.

    Returns the rewritten command and the ordered list of heredoc bodies.
    Each `<<TAG\\n...body...\\nTAG` becomes `<<TAG __HEREDOC_N__ TAG`.
    For `<<-TAG`, leading tabs are stripped from body lines per Bash semantics.
    """
    bodies: list[str] = []

    def replace(m: re.Match) -> str:
        indent_strip = m.group(1) == "-"
        tag = m.group(2)
        body = m.group(3)
        if indent_strip:
            body = "\n".join(line.lstrip("\t") for line in body.split("\n"))
        idx = len(bodies)
        bodies.append(body)
        return f"<<{tag} __HEREDOC_{idx}__ {tag}"

    return _HEREDOC_RE.sub(replace, cmd), bodies


def _split_git_prefix(tokens: list[str]) -> tuple[str | None, list[str]] | None:
    """Walk tokens starting at 'git' and consume option flags until 'commit'.

    Returns (git_C, args_after_commit) or None if 'git commit' is not the
    structure (e.g. 'git push', 'git status').
    """
    i = 0
    while i < len(tokens) and tokens[i] != "git":
        i += 1
    if i == len(tokens):
        return None
    i += 1
    git_c: str | None = None
    while i < len(tokens):
        t = tokens[i]
        if t == "-C" and i + 1 < len(tokens):
            git_c = tokens[i + 1]
            i += 2
            continue
        if t == "-c" and i + 1 < len(tokens):
            i += 2
            continue
        if t.startswith("-c") and len(t) > 2:
            i += 1
            continue
        if t in {"--git-dir", "--work-tree", "--namespace", "--super-prefix"}:
            i += 2
            continue
        if t.startswith("--git-dir=") or t.startswith("--work-tree="):
            i += 1
            continue
        if t == "commit":
            return git_c, tokens[i + 1 :]
        # Anything else before 'commit' means this is not a 'git commit' invocation.
        return None
    return None


def _parse_commit_args(args: list[str], heredoc_bodies: list[str]) -> dict:
    messages: list[str] = []
    file_messages: list[str] = []
    amend = False
    allow_empty = False
    autosquash: str | None = None  # 'fixup', 'squash', 'reword'
    parse_error = False
    reason = ""
    heredoc_used = False

    def resolve_heredoc(value: str) -> tuple[str, bool]:
        m = _PLACEHOLDER_RE.search(value)
        if not m:
            return value, False
        try:
            idx = int(m.group(1))
            return heredoc_bodies[idx], True
        except (ValueError, IndexError):
            return value, False

    i = 0
    while i < len(args):
        a = args[i]
        if a == "-m" or a == "--message":
            if i + 1 >= len(args):
                parse_error = True
                reason = f"{a} flag without value"
                break
            v, used = resolve_heredoc(args[i + 1])
            heredoc_used = heredoc_used or used
            messages.append(v)
            i += 2
            continue
        if a.startswith("-m") and a != "-m":
            v_raw = a[2:]
            if v_raw.startswith("="):
                v_raw = v_raw[1:]
            v, used = resolve_heredoc(v_raw)
            heredoc_used = heredoc_used or used
            messages.append(v)
            i += 1
            continue
        if a.startswith("--message="):
            v_raw = a[len("--message=") :]
            v, used = resolve_heredoc(v_raw)
            heredoc_used = heredoc_used or used
            messages.append(v)
            i += 1
            continue
        if a == "-F" or a == "--file":
            if i + 1 >= len(args):
                parse_error = True
                reason = f"{a} flag without value"
                break
            file_messages.append(args[i + 1])
            i += 2
            continue
        if a.startswith("--file="):
            file_messages.append(a[len("--file=") :])
            i += 1
            continue
        if a == "--amend":
            amend = True
            i += 1
            continue
        if a == "--allow-empty-message":
            allow_empty = True
            i += 1
            continue
        if a in {"--fixup", "--squash"}:
            autosquash = a[2:]
            i += 2  # consume the commit ref
            continue
        if a.startswith("--fixup=") or a.startswith("--squash="):
            autosquash = a[2:].split("=", 1)[0]
            i += 1
            continue
        i += 1

    return {
        "messages": messages,
        "file_messages": file_messages,
        "amend": amend,
        "allow_empty_message": allow_empty,
        "autosquash": autosquash,
        "parse_error": parse_error,
        "reason": reason,
        "heredoc_used": heredoc_used,
    }


def parse(cmd: str) -> dict:
    if not re.search(r"\bgit\b", cmd) or not re.search(r"\bcommit\b", cmd):
        return {"is_git_commit": False}
    segment = _find_git_commit_segment(cmd)
    cmd_with_placeholders, heredocs = _replace_heredocs(segment)
    try:
        tokens = shlex.split(cmd_with_placeholders, posix=True)
    except ValueError as e:
        return {"is_git_commit": False, "parse_error": True, "reason": f"shlex: {e}"}

    found = _split_git_prefix(tokens)
    if not found:
        return {"is_git_commit": False}
    git_c, commit_args = found

    parsed = _parse_commit_args(commit_args, heredocs)

    msg: str | None = None
    msg_source: str | None = None
    if parsed["messages"]:
        msg = "\n\n".join(parsed["messages"])
        msg_source = "heredoc" if parsed["heredoc_used"] else "m"
    elif parsed["file_messages"]:
        msg_source = "F"
    elif parsed["amend"]:
        msg_source = "amend"

    return {
        "is_git_commit": True,
        "git_C": git_c,
        "amend": parsed["amend"],
        "allow_empty_message": parsed["allow_empty_message"],
        "autosquash": parsed["autosquash"],
        "messages": parsed["messages"],
        "file_messages": parsed["file_messages"],
        "extracted_message": msg,
        "extracted_message_source": msg_source,
        "heredoc_used": parsed["heredoc_used"],
        "parse_error": parsed["parse_error"],
        "reason": parsed["reason"],
    }


def main() -> int:
    cmd = sys.stdin.read()
    try:
        result = parse(cmd)
    except Exception as e:
        result = {"is_git_commit": False, "parse_error": True, "reason": f"internal: {e}"}
    sys.stdout.write(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
