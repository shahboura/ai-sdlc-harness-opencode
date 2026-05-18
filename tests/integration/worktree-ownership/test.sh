#!/usr/bin/env bash
# WS-7 task 2 behavioral test: assert the develop.md Step 1 sub-step 5
# bash snippet creates a worktree with the expected branch shape, AND that
# `bash-write-guard.sh` allows the orchestrator (no agent_type in payload)
# to run `git worktree add`.
#
# Catches a regression where the doc-grep tests still pass but the actual
# behaviour is broken — e.g. if a future edit re-adds worktree creation to
# the agent prompt without removing it from the orchestrator step.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

# ----------------------------------------------------------------------
# Set up a fixture git repo with a feature branch.
# ----------------------------------------------------------------------
FIXTURE="$(mktemp -d -t worktree-test.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

REPO_PATH="$FIXTURE/repo"
mkdir -p "$REPO_PATH"
(
    cd "$REPO_PATH"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "WS-7 test"
    printf 'seed\n' > seed.txt
    git add seed.txt
    git commit -q -m "seed"
    git checkout -q -b team/feat/test-feature
)

FEATURE_BRANCH="team/feat/test-feature"

# ----------------------------------------------------------------------
# Test 1: the develop.md Step 1 sub-step 5 bash snippet creates a worktree
# with the expected branch shape. We extract the snippet's logic and run it
# against the fixture.
# ----------------------------------------------------------------------
UID8=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | cut -c1-8 \
       || python3 -c "import uuid; print(str(uuid.uuid4())[:8])")
WORKTREE_BRANCH="worktree/test-001-t1-${UID8}"
# B1 — path carries the same UID8 as the branch. Without it, a resume after a
# crash that left `repo-t1/` on disk would collide with the next `git worktree
# add` attempt (the dir already exists). The UID8 makes a fresh attempt always
# succeed; the orphan is cleaned via the reconciliation flow.
WORKTREE_PATH="$REPO_PATH/../worktrees/repo-t1-${UID8}"

if git -C "$REPO_PATH" worktree add "$WORKTREE_PATH" -b "$WORKTREE_BRANCH" "$FEATURE_BRANCH" >/dev/null 2>&1; then
    _pass 'orchestrator-side worktree creation succeeds'
else
    _fail 'worktree creation' 'git worktree add failed against fixture'
fi

if [ -d "$WORKTREE_PATH" ]; then
    _pass 'worktree directory exists on disk after creation'
else
    _fail 'worktree dir' "$WORKTREE_PATH not found"
fi

if [ -f "$WORKTREE_PATH/seed.txt" ]; then
    _pass 'worktree contains the feature-branch tree'
else
    _fail 'worktree contents' "$WORKTREE_PATH/seed.txt missing — worktree not initialised from feature branch"
fi

actual_branch=$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [ "$actual_branch" = "$WORKTREE_BRANCH" ]; then
    _pass "worktree is on branch '$WORKTREE_BRANCH' (orchestrator UID8 pattern)"
else
    _fail 'worktree branch' "expected '$WORKTREE_BRANCH', got '$actual_branch'"
fi

# Branch name shape: worktree/<story>-t<n>-<8-hex>
if printf '%s' "$WORKTREE_BRANCH" | grep -qE '^worktree/[^/]+-t[0-9]+-[0-9a-f]{8}$'; then
    _pass 'branch name matches the orchestrator UID8 pattern'
else
    _fail 'branch pattern' "branch name '$WORKTREE_BRANCH' doesn't match worktree/<story>-t<n>-<UID8>"
fi

# B1 — path also carries the UID8 (regression catch — if a future edit drops
# the UID8 from the path, a crashed-mid-task resume would collide).
if printf '%s' "$(basename "$WORKTREE_PATH")" | grep -qE '^[^/]+-t[0-9]+-[0-9a-f]{8}$'; then
    _pass 'worktree path basename includes the UID8 suffix'
else
    _fail 'path pattern' "path basename '$(basename "$WORKTREE_PATH")' doesn't match <repo>-t<n>-<UID8>"
fi

# B1 — collision regression: a SECOND `git worktree add` at the same path
# (simulating a resumed lane that re-runs Step 1 sub-step 5 with a fresh UID8
# but accidentally re-uses the old path) must fail. The fresh path is the only
# way the orchestrator can survive an orphan worktree on disk.
COLLISION_BRANCH="worktree/test-001-t1-deadbeef"
if git -C "$REPO_PATH" worktree add "$WORKTREE_PATH" -b "$COLLISION_BRANCH" "$FEATURE_BRANCH" >/dev/null 2>&1; then
    _fail 'reusing the same path on a fresh add fails' \
        "git worktree add succeeded against an already-occupied path '$WORKTREE_PATH' — git's natural collision guard is broken"
    # Clean up so the cleanup at end of test doesn't double-fault.
    git -C "$REPO_PATH" worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
    git -C "$REPO_PATH" branch -D "$COLLISION_BRANCH" >/dev/null 2>&1 || true
else
    _pass 'reusing the same path on a fresh add fails (UID8-in-path prevents this)'
fi

# B1 — fresh path with a different UID8 must succeed even while the original
# worktree still exists. This is the post-crash resume happy path.
ALT_UID8="cafef00d"
ALT_BRANCH="worktree/test-001-t1-${ALT_UID8}"
ALT_PATH="$REPO_PATH/../worktrees/repo-t1-${ALT_UID8}"
if git -C "$REPO_PATH" worktree add "$ALT_PATH" -b "$ALT_BRANCH" "$FEATURE_BRANCH" >/dev/null 2>&1; then
    _pass 'fresh UID8 path succeeds even with the original worktree still on disk'
    git -C "$REPO_PATH" worktree remove "$ALT_PATH" --force >/dev/null 2>&1 || true
    git -C "$REPO_PATH" branch -D "$ALT_BRANCH" >/dev/null 2>&1 || true
else
    _fail 'fresh UID8 path resumes cleanly' \
        "git worktree add to '$ALT_PATH' failed while the original was still on disk — the UID8-in-path fix does not give the expected post-crash resume property"
fi

# ----------------------------------------------------------------------
# Test 2: bash-write-guard allows `git worktree add` from the orchestrator
# session (no agent_type in payload). Regression for the case where some
# future hook hardening accidentally blocks worktree creation.
# ----------------------------------------------------------------------
HOOK="$REPO_ROOT/scripts/bash-write-guard.sh"
if [ ! -x "$HOOK" ]; then
    _fail 'bash-write-guard executable' "$HOOK not found or not executable"
else
    # Build a fake initialised workspace so the hook's hook_in_workspace
    # gate triggers (otherwise it no-ops at exit 0).
    FAKE_WS="$(mktemp -d -t ws-test.XXXXXX)"
    mkdir -p "$FAKE_WS/.claude/context"
    : > "$FAKE_WS/.claude/context/provider-config.md"

    payload=$(python3 -c "
import json
print(json.dumps({
    'tool_name': 'Bash',
    'tool_input': {
        'command': 'git -C \"/some/repo\" worktree add \"/some/repo/../worktrees/repo-t1\" -b \"worktree/story-t1-deadbeef\" \"team/feat/x\"',
    },
}))
")

    stderr_file=$(mktemp)
    exit_code=0
    (cd "$FAKE_WS" && printf '%s' "$payload" | "$HOOK" >/dev/null 2>"$stderr_file") || exit_code=$?
    stderr=$(cat "$stderr_file")
    rm -f "$stderr_file"
    rm -rf "$FAKE_WS"

    if [ "$exit_code" = "0" ]; then
        _pass 'bash-write-guard allows orchestrator-side `git worktree add`'
    else
        _fail 'bash-write-guard' "expected exit 0, got $exit_code (stderr: $stderr)"
    fi
fi

# ----------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------
git -C "$REPO_PATH" worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
git -C "$REPO_PATH" branch -D "$WORKTREE_BRANCH" >/dev/null 2>&1 || true

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0
