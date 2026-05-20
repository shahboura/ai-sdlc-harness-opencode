# Error Handling

> Owner: cross-cutting
> Version: 1.0

<!-- Extracted from orchestrator-rules.md by dev-workflow-plan.md [M-26] [IMPL-26-03]
     Reason: US-E03-004 surgery — moved per-phase detail to context file to bring
     orchestrator-rules.md within CC-04.8 hard cap.
     CC conventions applied: CC-04.8 (context-file budget), CC-04.4. -->

> Authoritative reference: consumed by `commands/review-response.md` and `commands/handle-request.md`.

## Subagent File Operation Errors

After **every** Planner agent invocation that involves writing plan or tracker files, check the agent's response for error markers:

- `⚠️ FILE OPERATION FAILED` — the Planner could not save a file.
- `⚠️ FILE OPERATION BLOCKED` — the write-guard hook blocked an out-of-scope write.

**If an error is reported:**
1. Log the error details.
2. If the path was wrong (blocked by hook), correct the path and re-invoke the Planner with explicit instructions:
   ```
   @ai-sdlc-planner Save the plan to <WORKSPACE_ROOT>/ai/<YYYY-MM-DD>-<work-item-id>/plan.md
   (canonical M-14 layout per skills/dev-workflow/context/workflow-paths.md; legacy
   <WORKSPACE_ROOT>/ai/plans/<correct-filename> accepted during the migration window).
   Use the absolute workspace path — never a code-repo path. Verify the
   file was saved by reading it back.
   ```
3. If the Write tool itself failed (disk error, permissions), retry once. If it fails again, report to the human user and pause the workflow.

## File Operation Error Markers

Scan for these error markers in agent responses (especially from the Planner):

```
⚠️ FILE OPERATION FAILED
- Operation: Write | Edit
- Target path: <path>
- Error: <error message>
- Action taken: <what the agent tried>
```

**If found:** correct the path and re-invoke, or pause and report to human.

## General Error Recovery

- If a session ends mid-workflow, the task tracker preserves state.
- The next session reads the tracker and resumes from the correct point.
- The `inject-tracker-state` hook automatically loads tracker state when agents start.

## API Failure Recovery

If an agent turn ends unexpectedly (API error, timeout), the `StopFailure` hook automatically:
1. Captures the current tracker state
2. Detects in-progress tasks and uncommitted changes
3. Injects resume instructions into the next turn

The orchestrator should read the recovery context and resume from the exact point of failure.

## Worktree Reconciliation on Resume

Mid-task interruptions (API error, user abort, session timeout) leave worktrees on disk that may or may not be load-bearing for the resume. The orchestrator MUST reconcile them before resuming work — and at the start of any new Phase 3 invocation for an existing tracker — using the procedure injected by `stop-failure-recovery.sh` and the `PostCompact` hook:

1. For each repo from `repos-paths.md`, list worktrees with `git -C "<repo-path>" worktree list --porcelain`.
2. Match each worktree branch against the canonical pattern `worktree/<story-id>-t<n>-<uid8>` (created by `develop.md` Step 1 sub-step 5). Unmatched worktrees are out-of-scope (developer-owned or unrelated) — leave alone.
3. For each matched worktree, look up Task `T<n>` in the current tracker and classify:
   - **🔧 In Progress / 🔄 In Review** → **preserve.** This is the worktree the resumed lane will pick up. Restore `WORKTREE_PATH` and `WORKTREE_BRANCH` to the lane state.
   - **✅ Done** → **remove.** The squash-merge already completed; the worktree is stale.
   - **No matching task row** → **remove.** Stale from an aborted-pre-tracker session or a renamed task.
   - **⏳ Pending** with no impl/test commits in the worktree → **remove.** The lane never started; a fresh worktree will be created when the task is launched.

   **Multiple worktrees matching the same In Progress / In Review task** — this happens when a previous attempt crashed and left an orphan worktree on disk, and the next resume created a fresh worktree with a different UID8 (per `develop.md` Step 1 sub-step 5). Both worktrees have valid `worktree/<story-id>-t<n>-<uid8>` branches and both map to the same task row; classifying both as `preserve` would leave the orchestrator with no deterministic way to pick which worktree the resumed lane should use. Resolution:
   - **Pick the most recently modified worktree as `preserve`** — use `git -C "<worktree-path>" log -1 --format=%ct HEAD` (Unix timestamp of the latest commit) as the tie-breaker. If neither has any commits yet, fall back to the worktree directory's mtime (`stat -c %Y` on Linux, `stat -f %m` on macOS).
   - **Classify every other matching worktree as `remove`** with the reason "duplicate worktree for task T<n>; the kept one is `<picked-path>`".
   - Restore `WORKTREE_PATH` / `WORKTREE_BRANCH` from the picked worktree.
   - This rule fires only when both worktrees have a matching branch shape AND a tracker row in `🔧 In Progress` / `🔄 In Review`. Worktrees with `✅ Done` / no-matching-row / `⏳ Pending` rows are removed regardless of count — the earlier rows of this table already cover them.
4. Surface the classification table to the human and request confirmation before pruning. Never auto-remove worktrees in the same turn — `git worktree remove` is destructive (deletes uncommitted work). Once the human confirms, run `git -C "<repo-path>" worktree remove "<worktree-path>"` followed by `git -C "<repo-path>" branch -D "<branch>"` for each `remove`-classified entry.
5. Repos running in the worktree-failed fallback (no worktrees, work happens on the feature branch directly) are a valid state — do not flag them.
