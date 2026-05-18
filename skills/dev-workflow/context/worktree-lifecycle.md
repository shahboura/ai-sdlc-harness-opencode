# Worktree Lifecycle

> Owner: cross-cutting
> Version: 1.0

<!-- Created by: dev-workflow-plan.md [M-01] [IMPL-01-03]
     Reason: Foundational shared snippet — extracts worktree create/cleanup pattern duplicated in develop.md + fix loop.
     CC conventions applied: CC-04.2, CC-04.4 -->

## Purpose

Single source for git-worktree lifecycle used by P3 development loop, P5 test hardening, P5.5 security review, and the IG fix loop. Per CC-05.6, fan-out lanes execute in isolated worktrees.

## Naming convention

Worktrees are named `<repo>-t<n>-<uid8>`:

- `<repo>` — repository slug from `provider-config.md`.
- `<n>` — task number from the plan (1-based).
- `<uid8>` — 8-character random suffix to guarantee uniqueness across parallel lanes and resumed sessions.

Example: `web-app-t3-a7c4e102`.

## Create

```bash
WT_BASE="${WORKSPACE_ROOT}/.worktrees"
mkdir -p "$WT_BASE"
uid8=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c8)
WT_NAME="${repo}-t${task_n}-${uid8}"
WT_PATH="${WT_BASE}/${WT_NAME}"

if ! git -C "$repo_path" worktree add -b "${branch_name}" "$WT_PATH" "$base_branch"; then
  echo "worktree_failed: true" >> "$tracker"
  exit 2
fi
echo "Worktree created: ${WT_PATH}" >> "$tracker"
```

## Cleanup

On task success (after squash-merge to feature branch):

```bash
git -C "$repo_path" worktree remove --force "$WT_PATH"
git -C "$repo_path" branch -D "${branch_name}"
echo "Worktree removed: ${WT_PATH}" >> "$tracker"
```

On task abandon (R recovery routed in):

```bash
git -C "$repo_path" worktree remove --force "$WT_PATH" 2>/dev/null || true
echo "Worktree abandoned: ${WT_PATH}" >> "$tracker"
```

## Fallback contract — `worktree_failed: true`

When `git worktree add` fails (path collision, branch already checked out, fs error), the consumer:

1. Writes `worktree_failed: true` to the tracker's metrics block.
2. Emits an `Outcome: BLOCKED` status block with `Reason: worktree creation failed for <repo> task <n>`.
3. Falls back to a direct-branch flow: the agent checks out the feature branch in the parent repo working tree (no worktree isolation); the developer / tester reports `Worktree: not used (direct branch)` and `Worktree branch: n/a`.
4. Routes to R for recovery only if the direct-branch fallback also fails; otherwise the workflow continues with reduced isolation.

This fail-safe boundary is what `agents/shared/status-schema.md` documents as `Worktree: not used (direct branch)` / `Worktree branch: n/a`. Silently retrying the worktree add without recording the failure is a CC-04.5 drift signal.

> **Layering vs `commands/develop.md`**: this is the **orchestrator-side** rule —
> the orchestrator owns worktree creation in `develop.md` Step 1 sub-step 5 and
> handles failure deterministically per the contract above. The `develop.md`
> "treat as warning and proceed" clause is the **agent-side** rule for legacy
> agents that still re-report worktree-creation failures the orchestrator
> already absorbed; those reports are noise, not a fresh failure event. The two
> rules describe the same failure at different layers and are not contradictory.

## Consumers

| Phase | Skill / Command | Use case |
|---|---|---|
| P3 | `commands/develop.md` Step 1.5 | Per-task worktree for parallel TDD |
| P3 | `commands/develop.md` fix-loop | Re-use task worktree across review rounds |
| P5 | `commands/test.md` | Auto-harden runs on feature branch directly (`Worktree: not used (direct branch)`); fallback to worktree only if explicit reuse declared |
| P5.5 | `commands/security-review.md` | Read-only worktree for SAST scan |
| P7 | `commands/review-response.md` | Re-enter P3 worktree for amendments |
| IG | `commands/handle-request.md` | Re-enter task worktree for ad-hoc fixes |

## Citation form

Per CC-04.3, every consumer cites this file with:

```markdown
> Authoritative reference: [worktree-lifecycle](../context/worktree-lifecycle.md)
```

Inlining the `git worktree add` / `worktree remove` logic in a command file is a CC-04.5 drift signal.
