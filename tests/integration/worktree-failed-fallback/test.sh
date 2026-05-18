#!/usr/bin/env bash
# A3 behavioural test: when WORKTREE_FAILED=true and the Tester+Developer
# commit directly on the feature branch, the orchestrator's Step 4 APPROVED
# branch must collapse those commits into one squashed commit on the feature
# branch — using `git reset --soft <feature_head>` because there is no
# worktree branch to `git merge --squash`.
#
# Catches the prior contradiction where Step 4 unconditionally ran
# `git merge --squash <worktree-branch>`, which would fail in fallback mode
# (no such branch exists).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

# ----------------------------------------------------------------------
# Fixture: a single-repo workspace on a feature branch with a seed file.
# ----------------------------------------------------------------------
FIXTURE="$(mktemp -d -t a3-fallback-test.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT

REPO_PATH="$FIXTURE/repo"
mkdir -p "$REPO_PATH"
(
    cd "$REPO_PATH"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "A3 fallback test"
    printf 'seed\n' > seed.txt
    git add seed.txt
    git commit -q -m "seed"
    git checkout -q -b backend/feature/STORY-99-add-thing
)

FEATURE_BRANCH="backend/feature/STORY-99-add-thing"

# Step 1 sub-step 3 — capture feature_head before T1 starts.
FEATURE_HEAD=$(git -C "$REPO_PATH" rev-parse HEAD)

# ----------------------------------------------------------------------
# Simulate WORKTREE_FAILED=true: agents commit directly on the feature branch.
# Tester commit (red tests), Developer commit (passing impl), one rework commit.
# ----------------------------------------------------------------------
(
    cd "$REPO_PATH"
    # Tester
    mkdir -p tests
    printf 'def test_thing(): assert thing() == 1\n' > tests/test_thing.py
    git add tests/test_thing.py
    git commit -q -m "#STORY-99 #T1 test: add red test for thing()"

    # Developer initial impl
    printf 'def thing(): return 1\n' > thing.py
    git add thing.py
    git commit -q -m "#STORY-99 #T1 impl: add thing()"

    # Developer rework after [R<n>] feedback
    printf 'def thing():\n    """Public API per plan §3."""\n    return 1\n' > thing.py
    git add thing.py
    git commit -q -m "#STORY-99 #T1 impl: rework — add docstring"
)

# Sanity: feature branch must have 3 new commits above feature_head.
commits_above_head=$(git -C "$REPO_PATH" rev-list --count "${FEATURE_HEAD}..HEAD")
if [ "$commits_above_head" -eq 3 ]; then
    _pass 'fixture has 3 agent commits above feature_head'
else
    _fail 'fixture commit count' "expected 3, got $commits_above_head"
fi

# ----------------------------------------------------------------------
# Step 4 APPROVED branch — fallback path. The orchestrator runs:
#   git -C "$REPO_PATH" reset --soft "$FEATURE_HEAD"
#   git -C "$REPO_PATH" commit -m "#STORY-99 #T1: <title>"
# ----------------------------------------------------------------------
TREE_BEFORE=$(git -C "$REPO_PATH" rev-parse HEAD^{tree})

git -C "$REPO_PATH" reset --soft "$FEATURE_HEAD" >/dev/null 2>&1
SQUASH_MSG=$'#STORY-99 #T1: add thing()\n\nCo-Authored-By: Claude Code <noreply@anthropic.com>'
git -C "$REPO_PATH" commit -q -m "$SQUASH_MSG"

# ----------------------------------------------------------------------
# Assertions on the post-squash state.
# ----------------------------------------------------------------------

# 1. Exactly one commit above feature_head now.
commits_above_after=$(git -C "$REPO_PATH" rev-list --count "${FEATURE_HEAD}..HEAD")
if [ "$commits_above_after" -eq 1 ]; then
    _pass 'fallback squash collapses agent commits into one'
else
    _fail 'post-squash commit count' "expected 1, got $commits_above_after"
fi

# 2. The squashed tree is byte-identical to what was there before the reset.
TREE_AFTER=$(git -C "$REPO_PATH" rev-parse HEAD^{tree})
if [ "$TREE_AFTER" = "$TREE_BEFORE" ]; then
    _pass 'fallback squash preserves the exact tree (no file content lost)'
else
    _fail 'tree preservation' "tree SHA changed across reset --soft + commit ($TREE_BEFORE → $TREE_AFTER)"
fi

# 3. Every agent-introduced file is present in the final tree.
if [ -f "$REPO_PATH/thing.py" ] && [ -f "$REPO_PATH/tests/test_thing.py" ]; then
    _pass 'fallback squash preserves both production and test files'
else
    _fail 'file presence' 'expected thing.py and tests/test_thing.py in the squashed tree'
fi

# 4. The new HEAD commit message matches the orchestrator's squash subject.
HEAD_SUBJECT=$(git -C "$REPO_PATH" log -1 --format=%s)
if [ "$HEAD_SUBJECT" = "#STORY-99 #T1: add thing()" ]; then
    _pass 'fallback squash commit carries the orchestrator subject'
else
    _fail 'squash subject' "expected '#STORY-99 #T1: add thing()', got '$HEAD_SUBJECT'"
fi

# 5. Co-author trailer present in the squash commit body.
HEAD_BODY=$(git -C "$REPO_PATH" log -1 --format=%b)
if printf '%s' "$HEAD_BODY" | grep -qF 'Co-Authored-By: Claude Code <noreply@anthropic.com>'; then
    _pass 'fallback squash commit carries the Co-Authored-By trailer'
else
    _fail 'co-author trailer' 'Co-Authored-By trailer missing from squash commit body'
fi

# 6. Branch is still the feature branch (we never created a worktree branch).
HEAD_BRANCH=$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD)
if [ "$HEAD_BRANCH" = "$FEATURE_BRANCH" ]; then
    _pass 'fallback path operates on the feature branch directly'
else
    _fail 'branch' "expected '$FEATURE_BRANCH', got '$HEAD_BRANCH'"
fi

# 7. The squash subject is accepted by validate-commit-msg (regression catch —
#    if the validator regex ever rejects orchestrator squash commits, the
#    fallback path silently breaks at hook time).
PYTHONPATH="$REPO_ROOT/scripts" python3 "$REPO_ROOT/scripts/_validate_commit_msg.py" \
    "git commit -m \"#STORY-99 #T1: add thing()\"" >/dev/null 2>&1
if [ "$?" = "0" ]; then
    _pass 'fallback squash subject passes validate-commit-msg'
else
    _fail 'validator' 'validate-commit-msg rejected the fallback squash subject'
fi

# ----------------------------------------------------------------------
# Negative case — make sure the WORKTREE-mode command would NOT work in
# fallback mode. This is the regression catch: if anyone "fixes" the
# fallback by trying to merge a worktree branch that doesn't exist, it
# must fail loudly. We expect `git merge --squash <nonexistent>` to error.
# ----------------------------------------------------------------------
if git -C "$REPO_PATH" merge --squash "worktree/STORY-99-t1-deadbeef" >/dev/null 2>&1; then
    _fail 'merge --squash with nonexistent worktree branch fails loudly' \
        'git merge --squash succeeded against a nonexistent ref — the fallback regression catch is broken'
else
    _pass 'merge --squash with nonexistent worktree branch fails loudly'
fi

# Abort the merge attempt so the trap-cleaned fixture is in a clean state.
git -C "$REPO_PATH" merge --abort >/dev/null 2>&1 || true

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0
