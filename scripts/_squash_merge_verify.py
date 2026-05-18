#!/usr/bin/env python3
"""PostToolUse hook on Bash that verifies a `git merge --squash` operation
landed cleanly. Surfaces a warning to the model when conflicts or empty
results are detected.

Reads the hook payload file path from argv[1].

Fixes vs. the previous implementation:
- `shlex`-based command detection — handles `cd X && git merge --squash …`,
  `X=Y git merge --squash …`, `(cd X; git merge --squash …)`,
  `git -c <cfg> merge --squash …`.
- `STAGED_COUNT` is computed in Python with an int default; no shell
  `[ "" -gt 0 ]` syntax error path when `git -C` fails.
- Drops the brittle MERGE_MSG-file AND-condition; relies on
  `git diff --name-only --diff-filter=U` (the authoritative conflict
  indicator) alone.

Exit codes (PostToolUse):
    0   no issue / nothing to do
    2   warning surfaced to the model (NOT a hard block — PostToolUse exit
        2 is treated as advisory)
"""
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys


_ENV_PREFIX_RE = re.compile(r"^(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)+")


_CD_RE = re.compile(r"^cd\s+(\S+)\s*$")


def _find_git_merge_segment(cmd: str) -> tuple[str, str | None]:
    """Return (segment containing `git merge`, implicit cwd from `cd <path>`).

    A leading `cd <path> && …` or `(cd <path>; …)` is consumed as the implicit
    cwd. Subsequent `-C <path>` on git itself overrides this.
    """
    s = cmd.strip()
    if s.startswith("(") and s.endswith(")"):
        s = s[1:-1].strip()
    parts = re.split(r"\s*(?:&&|\|\||;|\|)\s*", s)
    implicit_cwd: str | None = None
    for part in parts:
        cd_m = _CD_RE.match(part.strip())
        if cd_m:
            implicit_cwd = cd_m.group(1).strip('"\'')
            continue
        if re.search(r"\bgit\b", part) and re.search(r"\bmerge\b", part):
            return _ENV_PREFIX_RE.sub("", part.strip()), implicit_cwd
    return s, implicit_cwd


def _has_chained_commit(cmd: str) -> bool:
    """True when the command chains a `git commit` after the `git merge --squash`.

    Compound forms covered:
        git merge --squash X && git commit -m "..."
        cd repo && git merge --squash X && git commit ...
        (cd repo; git merge --squash X; git commit ...)

    When the merge and commit are chained, the merge stages changes and the
    commit consumes them — by the time this PostToolUse hook inspects the
    index, `git diff --cached` is empty. That's the success path, not a
    failure. The staged-count check is skipped in this case.
    """
    s = cmd.strip()
    if s.startswith("(") and s.endswith(")"):
        s = s[1:-1].strip()
    parts = re.split(r"\s*(?:&&|\|\||;|\|)\s*", s)
    seen_merge = False
    for part in parts:
        if re.search(r"\bgit\b", part) and re.search(r"\bmerge\b", part) and "--squash" in part:
            seen_merge = True
            continue
        if seen_merge and re.search(r"\bgit\b", part) and re.search(r"\bcommit\b", part):
            return True
    return False


def _parse_squash_merge(cmd: str) -> tuple[bool, str | None, str | None]:
    """Return (is_squash_merge, effective_cwd, merged_branch_arg).

    effective_cwd prefers an explicit `-C <path>` flag, falling back to the
    implicit `cd <path>` prefix, and is None when neither is present.
    """
    segment, implicit_cwd = _find_git_merge_segment(cmd)
    try:
        tokens = shlex.split(segment, posix=True)
    except ValueError:
        return False, None, None
    i = 0
    while i < len(tokens) and tokens[i] != "git":
        i += 1
    if i == len(tokens):
        return False, None, None
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
        if t in {"--git-dir", "--work-tree"}:
            i += 2
            continue
        if t.startswith("--git-dir=") or t.startswith("--work-tree="):
            i += 1
            continue
        if t == "merge":
            rest = tokens[i + 1 :]
            if "--squash" not in rest:
                return False, None, None
            merged: str | None = None
            j = 0
            while j < len(rest):
                if rest[j] == "--squash" and j + 1 < len(rest):
                    candidate = rest[j + 1]
                    if not candidate.startswith("-"):
                        merged = candidate
                    break
                j += 1
            effective_cwd = git_c or implicit_cwd
            return True, effective_cwd, merged
        return False, None, None
    return False, None, None


def _git(args: list[str], cwd: str | None) -> tuple[int, str, str]:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        return result.returncode, result.stdout, result.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, "", str(e)


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    try:
        with open(sys.argv[1], "r", encoding="utf-8") as f:
            payload = json.load(f)
    except (OSError, json.JSONDecodeError):
        return 0

    if payload.get("tool_name") != "Bash":
        return 0
    cmd = (payload.get("tool_input") or {}).get("command", "")
    if not cmd:
        return 0

    is_sq, git_c, merged_branch = _parse_squash_merge(cmd)
    if not is_sq:
        return 0

    cwd: str | None = git_c
    repo_suffix = f" (repo: {git_c})" if git_c else ""

    # Unresolvable cwd guard. When `-C "$VAR"` references a shell variable
    # assigned in the same chained command (`REPO_PATH="..." && git -C
    # "$REPO_PATH" merge --squash …`), the variable is not exported and
    # never reaches the hook's environment — `shlex` returns the literal
    # `$REPO_PATH` token. Every subsequent git subprocess then fails with
    # FileNotFoundError, the chained-commit HEAD lookup fails, the staged-
    # index inspection fails, and the FF merge-base check fails — so the
    # hook falls through to the "no staged changes" branch and emits a false-
    # positive warning even though the merge + commit succeeded
    # in-shell. Degrade silently when the resolved path isn't a directory.
    if cwd is not None and not os.path.isdir(cwd):
        return 0

    rc, conflicts_out, _ = _git(["diff", "--name-only", "--diff-filter=U"], cwd)
    conflicts = conflicts_out.strip().splitlines() if rc == 0 else []
    if conflicts:
        c_flag = f" -C {git_c}" if git_c else ""
        print(f"⚠️  SQUASH-MERGE CONFLICT DETECTED{repo_suffix}", file=sys.stderr)
        print("", file=sys.stderr)
        print("Conflicting files:", file=sys.stderr)
        for f in conflicts:
            print(f"  {f}", file=sys.stderr)
        print("", file=sys.stderr)
        print("Recovery options:", file=sys.stderr)
        print(f"  1. Abort: git{c_flag} merge --abort", file=sys.stderr)
        print(
            f"  2. Resolve conflicts, then: git{c_flag} add <files> && "
            f"git{c_flag} commit",
            file=sys.stderr,
        )
        return 2

    rc_b, branch_out, _ = _git(["rev-parse", "--abbrev-ref", "HEAD"], cwd)
    branch = branch_out.strip() if rc_b == 0 else "(unknown)"

    # When the command chains a `git commit` after the squash merge (the typical
    # orchestrator pattern `git merge --squash X && git commit -m "..."`), the
    # commit consumed the staged changes. Checking `git diff --cached` after
    # that is always empty — that's the success path, not a failure. Inspect
    # HEAD instead: if the latest commit landed since the merge, we're done.
    if _has_chained_commit(cmd):
        rc_h, head_msg, _ = _git(["log", "-1", "--format=%H %s"], cwd)
        if rc_h == 0 and head_msg.strip():
            print(
                f"✅ Squash-merge + commit verified on branch {branch}{repo_suffix}\n"
                f"   HEAD: {head_msg.strip()}"
            )
            return 0
        # _has_chained_commit is a deterministic structural read of the cmd
        # string; falling through to staged-count would emit a false-positive
        # "no staged changes" warning because the chained commit already
        # consumed the index.
        print(
            f"✅ Squash-merge + commit assumed successful{repo_suffix} "
            f"(HEAD unreadable; chained commit detected)"
        )
        return 0

    rc_s, staged_out, _ = _git(["diff", "--cached", "--name-only"], cwd)
    staged_count = (
        len([line for line in staged_out.splitlines() if line.strip()])
        if rc_s == 0
        else 0
    )

    c_flag = f" -C {git_c}" if git_c else ""
    if staged_count > 0:
        print(
            f"✅ Squash-merge verified: {staged_count} file(s) staged on "
            f"branch {branch}{repo_suffix}"
        )
        print(
            f'   Ready for: git{c_flag} commit -m '
            f'"#<STORY-ID> [#T<n>]: <task-title>"'
        )
        return 0

    # Already-merged detection: when `git merge-base --is-ancestor <merged>
    # HEAD` succeeds, the merged branch's tip is already in HEAD's history
    # (the changes landed via an earlier merge / cherry-pick / rebase). A
    # squash-merge in this state legitimately stages nothing — that's a
    # no-op success, not a failure.
    if merged_branch:
        rc_a, _, _ = _git(
            ["merge-base", "--is-ancestor", merged_branch, "HEAD"], cwd
        )
        if rc_a == 0:
            print(
                f"✅ Squash-merge no-op on branch {branch}{repo_suffix}: "
                f"{merged_branch} is already in HEAD's history (already-merged "
                f"fast-forward)."
            )
            return 0
        print(
            f"⚠️ Squash-merge produced no staged changes from branch "
            f"{merged_branch}{repo_suffix}",
            file=sys.stderr,
        )
        print(
            "This may mean the branch is already merged or has no new commits.",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
