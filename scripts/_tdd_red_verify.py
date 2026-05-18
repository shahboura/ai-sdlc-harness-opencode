#!/usr/bin/env python3
"""PostToolUse hook on Bash — TDD red-verify enforcement.

Created by: dev-workflow-plan.md [M-20] [IMPL-20-01]
Reason: Enforce TDD outcome semantics behaviourally — not just invocation
order. The plan's existing P3 step ordering guarantees the tester commit
precedes the developer commit, but does nothing to detect a vacuous test
(`assertTrue(True)`) or an impl that doesn't actually pass its own test.
This hook replays the language-config test command against `HEAD~` (state
at tester-commit) and `HEAD` (state with impl commit) — blocks the developer
commit when probe-red passes OR probe-green fails.

Reads the hook payload file path from argv[1].

Policy: fail-CLOSED. Exit 2 blocks the implicit subsequent agent step.

Replay mechanics:
    Non-mutating. Uses `git worktree add --detach <scratch> <sha>` to create
    a separate scratch worktree per probe; runs the language-config test
    command inside the scratch worktree; removes the scratch worktree before
    returning. The developer's primary worktree is read-only from this hook.

Isolation (CC-03.3):
    Hook's only state mutation is `.claude/context/.tdd-verify/cache.json` +
    transient scratch worktrees under `.claude/context/.tdd-verify/<uid8>/`.
    Nothing under `ai/`, the developer worktree, or the feature branch.

Idempotency (CC-03.7):
    Re-invoking for the same `(HEAD~_sha, HEAD_sha)` pair short-circuits via
    the cache. Cache key includes `language-config.md` content hash so a
    toolchain change invalidates the cache.

Limits (documented, not silent):
    Detects the *structural* red→green flip. A test like
    `assertEqual(my_new_fn(), 42)` against `HEAD~` where `my_new_fn` doesn't
    exist yet will fail to import → counted as "red" even if the test is
    semantically empty. Semantic dead tests remain the reviewer's
    responsibility.

Exit codes:
    0  — verification passed OR hook is a no-op (not an impl commit)
    2  — verification failed; block the next step
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Optional

# Match `impl:` prefix anywhere in the commit subject; tolerates the leading
# `#<story-id> #<task-id>` prefix typical of harness commits.
_IMPL_SUBJECT_RE = re.compile(r"\bimpl:\s*", re.IGNORECASE)

# Scratch + cache live under `.claude/context/.tdd-verify/`.
_TDD_DIR_REL = Path(".claude/context/.tdd-verify")
_CACHE_FILE_REL = _TDD_DIR_REL / "cache.json"


def _workspace_root_from_cwd() -> Optional[Path]:
    """Walk up from cwd looking for `.claude/context/provider-config.md`."""
    d = Path.cwd()
    while True:
        if (d / ".claude" / "context" / "provider-config.md").is_file():
            return d
        if d.parent == d:
            return None
        d = d.parent


def _git(args: list[str], cwd: Path | str) -> tuple[int, str, str]:
    try:
        r = subprocess.run(
            ["git", *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        return r.returncode, r.stdout, r.stderr
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, "", str(e)


_GIT_COMMIT_RE = re.compile(r"\bgit(?:\s+-C\s+\"[^\"]+\"|\s+-C\s+\S+|\s+-c\s+\S+)*\s+commit\b")


def _parse_commit_subject(cmd: str) -> Optional[str]:
    """Extract the commit subject from a `git commit -m "..."` invocation.

    Tolerates heredocs, chained-command forms (`cd X && git commit`), and
    flag-prefixed forms (`git -C "path with spaces" commit`, `git -c k=v commit`).
    Returns None when the command isn't recognisably a `git commit` with `-m`.
    """
    if not _GIT_COMMIT_RE.search(cmd):
        return None
    # `-m "subject"` (double-quoted)
    m = re.search(r'-m\s+"([^"]+)"', cmd)
    if m:
        return m.group(1).strip().splitlines()[0].strip()
    # `-m 'subject'` (single-quoted)
    m = re.search(r"-m\s+'([^']+)'", cmd)
    if m:
        return m.group(1).strip().splitlines()[0].strip()
    # `-m subject-no-quotes` (token form)
    m = re.search(r"-m\s+(\S+)", cmd)
    if m:
        return m.group(1)
    return None


def _detect_repo_from_cmd(cmd: str, workspace_root: Path) -> Optional[Path]:
    """Resolve the repo path from `git -C <path>` or `cd <path> && git ...`."""
    m = re.search(r"git\s+-C\s+\"?([^\"\s&|;)]+)\"?\b", cmd)
    if m:
        return Path(m.group(1))
    m = re.search(r"\bcd\s+\"?([^\"\s&|;)]+)\"?\s+&&\s+git\b", cmd)
    if m:
        return Path(m.group(1))
    # Default to the workspace root (single-repo case where workspace == repo).
    if (workspace_root / ".git").exists():
        return workspace_root
    return None


def _test_command_for_repo(workspace_root: Path, repo_path: Path) -> Optional[list[str]]:
    """Resolve the per-repo test command from `.claude/context/language-config.md`.

    Returns the command as a token list (shlex-friendly), or None when the
    config is absent / unparseable. The language-config schema documents one
    block per repo with `repo:` and `test_cmd:` keys; we parse minimally.
    """
    config = workspace_root / ".claude" / "context" / "language-config.md"
    if not config.is_file():
        return None
    try:
        text = config.read_text(encoding="utf-8")
    except OSError:
        return None
    repo_name = repo_path.name
    # Block-by-block scan; each block keyed `repo: <name>`.
    blocks = re.split(r"\n(?=##\s+|repo:\s)", text)
    for block in blocks:
        if not re.search(rf"^\s*repo:\s*{re.escape(repo_name)}\b", block, re.MULTILINE):
            continue
        m = re.search(r"^\s*test_cmd:\s*(.+)$", block, re.MULTILINE)
        if not m:
            continue
        cmd_str = m.group(1).strip().strip('"').strip("'")
        if not cmd_str:
            return None
        return cmd_str.split()
    return None


def _config_fingerprint(workspace_root: Path) -> str:
    """SHA-256 of `language-config.md` for cache invalidation."""
    config = workspace_root / ".claude" / "context" / "language-config.md"
    try:
        return hashlib.sha256(config.read_bytes()).hexdigest()[:16]
    except OSError:
        return "no-config"


def _load_cache(workspace_root: Path) -> dict:
    p = workspace_root / _CACHE_FILE_REL
    if not p.is_file():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _save_cache(workspace_root: Path, cache: dict) -> None:
    p = workspace_root / _CACHE_FILE_REL
    p.parent.mkdir(parents=True, exist_ok=True)
    try:
        p.write_text(json.dumps(cache, indent=2), encoding="utf-8")
    except OSError:
        pass  # cache is best-effort


def _probe(workspace_root: Path, repo: Path, sha: str, test_cmd: list[str]) -> tuple[int, str]:
    """Run `test_cmd` against `sha` in a scratch worktree. Returns (rc, tail-stderr)."""
    scratch_id = uuid.uuid4().hex[:8]
    scratch_dir = workspace_root / _TDD_DIR_REL / scratch_id
    scratch_dir.parent.mkdir(parents=True, exist_ok=True)

    rc_add, _, err_add = _git(
        ["worktree", "add", "--detach", "--quiet", str(scratch_dir), sha], cwd=repo
    )
    if rc_add != 0:
        return 1, f"worktree add failed: {err_add.strip()}"

    try:
        r = subprocess.run(
            test_cmd,
            cwd=str(scratch_dir),
            capture_output=True,
            text=True,
            timeout=300,
            check=False,
        )
        tail = (r.stderr or r.stdout or "").splitlines()
        tail_str = "\n".join(tail[-10:])
        return r.returncode, tail_str
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, f"test invocation failed: {e}"
    finally:
        # Clean up scratch worktree.
        _git(["worktree", "remove", "--force", str(scratch_dir)], cwd=repo)
        try:
            shutil.rmtree(scratch_dir, ignore_errors=True)
        except OSError:
            pass


def _verify(workspace_root: Path, repo: Path, test_cmd: list[str]) -> tuple[int, str]:
    """Run probe-red on HEAD~ and probe-green on HEAD; return (exit_code, msg)."""
    rc_h, head_sha, _ = _git(["rev-parse", "HEAD"], cwd=repo)
    rc_p, parent_sha, _ = _git(["rev-parse", "HEAD~1"], cwd=repo)
    if rc_h != 0 or rc_p != 0:
        return 0, "[TDD] cannot resolve HEAD / HEAD~ — skipping verification"

    head_sha = head_sha.strip()
    parent_sha = parent_sha.strip()
    cfg_fp = _config_fingerprint(workspace_root)
    cache_key = f"{parent_sha}__{head_sha}__{cfg_fp}"

    cache = _load_cache(workspace_root)
    if cache_key in cache:
        cached = cache[cache_key]
        if cached.get("verdict") == "pass":
            return 0, f"[TDD] verified (cached): red→green transition genuine for {head_sha[:8]}"
        return 2, cached.get("msg", "[TDD] cached failure — re-run after fixing")

    # Probe-red: tests at HEAD~ must FAIL (≠ 0). If 0, tester wrote a vacuous test.
    rc_red, red_tail = _probe(workspace_root, repo, parent_sha, test_cmd)
    if rc_red == 0:
        msg = (
            f"[TDD] probe-red PASSED at HEAD~ ({parent_sha[:8]}) — tester's test does not actually "
            f"fail without the implementation. The red→green transition is not verifiable.\n"
            f"Last lines:\n{red_tail}\n\n"
            f"Recovery: re-invoke @ai-sdlc-tester with `mode: auto-tdd` to write a test that "
            f"genuinely fails against the pre-impl state."
        )
        cache[cache_key] = {"verdict": "fail", "msg": msg}
        _save_cache(workspace_root, cache)
        return 2, msg

    # Probe-green: tests at HEAD must PASS (= 0). If non-zero, impl is broken.
    rc_green, green_tail = _probe(workspace_root, repo, head_sha, test_cmd)
    if rc_green != 0:
        msg = (
            f"[TDD] probe-green FAILED at HEAD ({head_sha[:8]}) — the impl commit does not pass "
            f"its own test (rc={rc_green}).\n"
            f"Last lines:\n{green_tail}\n\n"
            f"Recovery: re-invoke @ai-sdlc-developer to fix the implementation OR @ai-sdlc-tester "
            f"if the test itself is wrong."
        )
        cache[cache_key] = {"verdict": "fail", "msg": msg}
        _save_cache(workspace_root, cache)
        return 2, msg

    msg = f"[TDD] verified: probe-red at {parent_sha[:8]} failed (rc={rc_red}); probe-green at {head_sha[:8]} passed."
    cache[cache_key] = {"verdict": "pass", "msg": msg}
    _save_cache(workspace_root, cache)
    return 0, msg


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

    subject = _parse_commit_subject(cmd)
    if not subject or not _IMPL_SUBJECT_RE.search(subject):
        # Not an impl commit (no `impl:` prefix in subject) — no-op.
        return 0

    workspace_root = _workspace_root_from_cwd()
    if workspace_root is None:
        # Outside an initialised workspace — fail-open. The hook only applies
        # to harness-managed P3 worktree commits.
        return 0

    repo = _detect_repo_from_cmd(cmd, workspace_root)
    if repo is None:
        return 0

    test_cmd = _test_command_for_repo(workspace_root, repo)
    if not test_cmd:
        # No test command configured for this repo — fail-open with stderr.
        print(
            f"[TDD] advisory: no test_cmd configured for {repo.name} in "
            f"language-config.md; skipping red-verify enforcement.",
            file=sys.stderr,
        )
        return 0

    code, msg = _verify(workspace_root, repo, test_cmd)
    stream = sys.stdout if code == 0 else sys.stderr
    print(msg, file=stream)
    return code


if __name__ == "__main__":
    sys.exit(main())
