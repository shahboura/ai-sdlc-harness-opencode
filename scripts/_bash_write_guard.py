#!/usr/bin/env python3
"""Bash-side write guard.

Reads the hook payload from a file path passed as argv[1] (the bash entry
hands us the temp file from _hook-lib.sh::hook_init).

Policy: fail-CLOSED on **recognized** writes, fail-OPEN on unparseable
Bash. We do not block when `shlex` can't tokenize the command — there are
too many legitimate weird-but-harmless shell forms (process substitution,
unusual quoting, embedded eval). The high-value gate is `validate-commit-msg`
for commits and this guard for redirect/cp/mv/tee/ln/dd patterns we can
identify.

Blocks Bash commands that write to paths the harness considers protected:

  1. Anything that writes under `./ai/` from a Bash call. The harness's
     ai/ directory (plans, trackers) is owned by orchestrator/planner
     Write/Edit calls — never shell-driven mutations. Closes the
     "echo ... > ai/<workflow-dir>/...md" loophole.  CC-05.7-OK: docstring example

  2. Anything that writes to a sensitive file pattern (`.env*`, `*.pem`,
     `id_rsa*`, etc.). Extends `sensitive-file-guard.sh` to Bash.

  3. Subagent-aware: when the hook fires inside a subagent call (the
     payload carries `agent_type` per Claude Code's documented schema),
     enforces per-role rules:
       - reviewer → no Bash file writes at all
       - planner  → writes only under `./ai/` (the inverse of rule 1)
       - developer/tester → cannot write under `./ai/` (covered by rule 1)

The `agent_type` value may be namespaced (e.g. `ai-sdlc-harness:reviewer:
reviewer`); we normalise by taking the last segment after `:` / `/`.
Older payload field names (`subagent_name`, etc.) are still accepted as a
fallback. If no identity is detectable, rules 1 and 2 still apply.

Exit codes:
    0   allow
    2   block
"""
from __future__ import annotations

import json
import os
import os.path
import re
import shlex
import sys

# Changed by: dev-workflow-plan.md [M-01] [IMPL-01-08]
# Reason: Delegate subagent-type detection to shared `_subagent_utils` (TEST-15 / CC-04.3 / CC-08.1).
# CC conventions applied: CC-04.3 (Python `from` import), CC-08.1 (DRY extraction).
from _sensitive_patterns import matches_sensitive as _matches_sensitive_basename
from _subagent_utils import normalize_agent_type


_HEREDOC_RE = re.compile(
    r"<<(-)?\s*[\"\']?(\w+)[\"\']?[^\n]*\n(.*?)\n[\t ]*\2(?:\b|$)",
    re.DOTALL,
)

_REDIRECT_OPERATORS = {">", ">>", ">|", "&>", "&>>", "2>", "2>>", "1>", "1>>"}
_REDIRECT_OP_RE = re.compile(r"^([12]?&?>>?\|?)(.*)$")


def _strip_heredocs(cmd: str) -> str:
    """Remove heredoc bodies so they don't confuse shlex tokenization.

    The body is collapsed to a placeholder line.
    """
    return _HEREDOC_RE.sub(lambda m: f"<<{m.group(2)} __HEREDOC_BODY__ {m.group(2)}", cmd)


def _is_redirect_token(token: str) -> tuple[bool, str | None]:
    """If token is a redirect operator (possibly with target appended),
    return (True, target_or_None).
    `target_or_None` is None if the target is in the next token.
    """
    if token in _REDIRECT_OPERATORS:
        return True, None
    m = _REDIRECT_OP_RE.match(token)
    if m and m.group(1) in _REDIRECT_OPERATORS and m.group(2):
        return True, m.group(2)
    return False, None


def _strip_quotes(p: str) -> str:
    """Strip outer matching quotes (single or double) once."""
    p = p.strip()
    if len(p) >= 2 and p[0] == p[-1] and p[0] in {'"', "'"}:
        p = p[1:-1]
    return p


def _normalize_path(p: str) -> str:
    """Strip quotes and collapse `.`/`..` segments via `os.path.normpath`.

    The result is still potentially relative — callers that need to compare
    against an absolute location should resolve via `_resolve_target`.
    `os.path.normpath` flattens `foo/../ai/bar` to `ai/bar`, closing the
    relative-traversal loophole that a literal substring check misses.
    """
    p = _strip_quotes(p)
    if not p:
        return p
    # `os.path.normpath` collapses `.`, `..`, and redundant separators.
    # It does NOT touch the filesystem, so it's safe and fast.
    return os.path.normpath(p)


def _resolve_target(path: str) -> str:
    """Resolve a write target to its real on-disk location, dereferencing
    symlinks along the way (`os.path.realpath`).

    Falls back to the normalised path on any error so the guard never
    silently drops a violation. Used by the protected-prefix checks to
    close the symlink loophole: `ln -s ai/tasks/x.md fake && tee fake`
    would otherwise look like a write to `fake`.
    """
    norm = _normalize_path(path)
    if not norm:
        return norm
    try:
        # `realpath` returns an absolute path. It also resolves symlinks
        # for any ancestor that already exists; missing tail components
        # are passed through unchanged, so non-existent targets still
        # produce a sensible absolute string we can pattern-match.
        return os.path.realpath(norm)
    except (OSError, ValueError):
        return norm


def _is_under_ai(path: str) -> bool:
    """True if `path` (or what it resolves to) lives under an `ai/` directory.

    Checks both the as-given normalised path and the realpath-resolved
    location, so `ln -s ai/tasks/foo fake && tee fake` is still flagged.
    """
    candidates = {_normalize_path(path), _resolve_target(path)}
    for p in candidates:
        if not p:
            continue
        if p == "ai" or p.startswith("ai/"):
            return True
        if "/ai/" in p:
            # Absolute paths into a workspace's ai/ — e.g. /tmp/x/ai/foo.
            # We don't know the workspace root; treat as protected.
            return True
    return False


def _matches_sensitive(path: str) -> bool:
    """Match the basename of `path` (and its realpath) against the sensitive
    deny-list. Resolving symlinks closes the
    `ln -s id_rsa innocent && tee innocent` bypass.
    """
    for p in (_normalize_path(path), _resolve_target(path)):
        if p and _matches_sensitive_basename(p):
            return True
    return False


def _extract_write_targets(cmd: str) -> list[tuple[str, str]]:
    """Return a list of (mechanism, target_path) tuples for every write the
    command performs.

    Mechanisms: 'redirect', 'tee', 'cp', 'mv', 'install', 'dd', 'ln'.
    Conservatively over-reports; the caller decides whether each target is
    protected.
    """
    cleaned = _strip_heredocs(cmd)
    try:
        tokens = shlex.split(cleaned, posix=True)
    except ValueError:
        return []

    targets: list[tuple[str, str]] = []
    i = 0
    while i < len(tokens):
        t = tokens[i]

        is_redir, inline_target = _is_redirect_token(t)
        if is_redir:
            if inline_target:
                targets.append(("redirect", inline_target))
                i += 1
            elif i + 1 < len(tokens):
                targets.append(("redirect", tokens[i + 1]))
                i += 2
            else:
                i += 1
            continue

        if t == "tee":
            j = i + 1
            while j < len(tokens):
                tj = tokens[j]
                if tj.startswith("-"):
                    j += 1
                    continue
                # 'tee' can target multiple files until end-of-segment
                while j < len(tokens) and not tokens[j].startswith("-") and tokens[j] not in {"|", "&&", "||", ";"}:
                    if tokens[j] in _REDIRECT_OPERATORS:
                        break
                    targets.append(("tee", tokens[j]))
                    j += 1
                break
            i = j
            continue

        if t in {"cp", "mv", "install"}:
            # last positional arg is the destination
            j = i + 1
            positionals = []
            while j < len(tokens):
                tj = tokens[j]
                if tj in {"|", "&&", "||", ";"} or tj in _REDIRECT_OPERATORS:
                    break
                is_r, _ = _is_redirect_token(tj)
                if is_r:
                    break
                if tj.startswith("-"):
                    # consume option, possibly with adjacent value
                    j += 1
                    continue
                positionals.append(tj)
                j += 1
            if len(positionals) >= 2:
                targets.append((t, positionals[-1]))
            i = j
            continue

        if t == "ln":
            # `ln -sf src dst` → dst is target. We only care about hardlinks /
            # symlinks because a writer can clobber the linked location.
            j = i + 1
            positionals = []
            while j < len(tokens):
                tj = tokens[j]
                if tj in {"|", "&&", "||", ";"} or tj in _REDIRECT_OPERATORS:
                    break
                is_r, _ = _is_redirect_token(tj)
                if is_r:
                    break
                if tj.startswith("-"):
                    j += 1
                    continue
                positionals.append(tj)
                j += 1
            if len(positionals) >= 2:
                targets.append(("ln", positionals[-1]))
            i = j
            continue

        if t.startswith("dd"):
            # `dd if=… of=…` — care about of=
            j = i
            while j < len(tokens):
                tj = tokens[j]
                if tj in {"|", "&&", "||", ";"} or tj in _REDIRECT_OPERATORS:
                    break
                if tj.startswith("of="):
                    targets.append(("dd", tj[3:]))
                j += 1
            i = j
            continue

        i += 1

    return targets


def _detect_subagent(payload: dict) -> str | None:
    """Identify the calling subagent from the hook payload.

    Delegates to `_subagent_utils.normalize_agent_type` per CC-04.3 / CC-08.1
    (M-01 IMPL-01-08). The wrapper is preserved so callsites keep a stable
    name; the implementation lives in the shared helper.
    """
    return normalize_agent_type(payload)


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
    command = (payload.get("tool_input") or {}).get("command", "")
    if not command:
        return 0

    targets = _extract_write_targets(command)
    if not targets:
        return 0

    subagent = _detect_subagent(payload)
    violations: list[str] = []

    for mechanism, path in targets:
        normalized = _normalize_path(path)
        if not normalized or normalized in {"/dev/null", "/dev/stdout", "/dev/stderr"}:
            continue

        # Rule 1: writes under ai/ are off-limits to Bash — those paths are
        # orchestrator/planner Write/Edit territory.
        if _is_under_ai(normalized):
            # Exception: planner is allowed to write under ai/ if it's doing
            # shell-driven mutations (rare but legitimate, e.g. tracker generation
            # via templating).
            if subagent != "planner":
                violations.append(
                    f"{mechanism} writes to harness-owned path: {path}"
                )

        # Rule 2: sensitive file targets are off-limits regardless of caller.
        if _matches_sensitive(normalized):
            violations.append(
                f"{mechanism} writes to a sensitive file: {path}"
            )

        # Rule 3a: reviewer is read-only.
        if subagent == "reviewer":
            violations.append(
                f"reviewer is read-only; {mechanism} would write to {path}"
            )

        # Rule 3b: planner writes only under ai/.
        elif subagent == "planner" and not _is_under_ai(normalized):
            # /tmp, /dev/null already filtered; everything else is out of scope
            if not normalized.startswith("/tmp/") and not normalized.startswith("/var/folders/"):
                violations.append(
                    f"planner can write only under ai/; {mechanism} target: {path}"
                )

    if not violations:
        return 0

    print("bash-write-guard: blocking command", file=sys.stderr)
    # de-dup while preserving order
    seen = set()
    for v in violations:
        if v in seen:
            continue
        seen.add(v)
        print(f"  - {v}", file=sys.stderr)
    print(f"Command: {command}", file=sys.stderr)
    if subagent:
        print(f"Subagent: {subagent}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
