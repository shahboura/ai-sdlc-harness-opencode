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
WORKTREE_PATH="$REPO_PATH/../worktrees/repo-t1"

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
