# Phase 3: TDD Development Loop

> Authoritative references: [timestamp](../context/timestamp.md), [agent-response](../context/agent-response.md), [worktree-lifecycle](../context/worktree-lifecycle.md), [comment-routing](../context/comment-routing.md), [parallel-lane](../context/parallel-lane.md), [naming-templates](../context/naming-templates.md)

> Naming-config (M-15 IMPL-15-04): commit templates are read from `.claude/context/naming-config.md` per CC-01.8 — never hardcoded. The `_validate_commit_msg.py` hook validates commit subjects against the configured template.

<!-- Changed by: dev-workflow-plan.md [M-04] [IMPL-04-01..06]
     Reason: Replace inline `date -u` literals, `📋 AGENT STATUS` parser prose, worktree-add bash, and `[S]/[R]/[T]` routing with citations to the M-01 shared snippets per CC-04.3 / CC-08.1.
     CC conventions applied: CC-04.3, CC-08.1, CC-07.3. -->

**Phase**: 3
**Actors**: Tester agent, Developer agent, and Reviewer agent (orchestrator coordinates)

## Prerequisites

- Plan approved (Phase 2 complete; HUMAN GATE #1 cleared).
- Task tracker exists at `ai/<YYYY-MM-DD>-<work-item-id>/tracker.md` (new) OR `ai/tasks/*.md` (legacy).
- Pre-flight complete — feature branches exist in every repo named in the tracker; plan commit has landed.

## Pre-Flight

Read the tracker (prefer `ai/*-${STORY_ID}/tracker.md`; fall back to `ai/tasks/*${STORY_ID}*.md`).

```bash
cat .claude/context/repos-paths.md
cat .claude/context/language-config.md
```

Parse **Repo Status** → `repo-name → { local-path, feature-branch, default-branch }`. Build language map per repo. Conventions at `.claude/context/conventions.md`. Legacy trackers (no Repo Status) → single lane from story metadata.

**Record metric:** If `Development started` is `—`, stamp it now (see [timestamp](../context/timestamp.md)).

## Execution Model

### Prompt Context Templates

Every agent launch includes standard context blocks: **LANGUAGE_CTX**, **REPO_CTX**, **WORKTREE_CTX**, and **CONTRACTS_CTX**. The full schema for each, including which fields to include or omit per agent role, lives in [`../context/prompt-templates.md`](../context/prompt-templates.md). The steps below reference these templates by name — do not retype them inline.

### Detect Mode

Build the lane map from the tracker's `Repo` column. Single-repo → one lane; multi-repo → one lane per repo. Same steps apply either way.

---

## Execution Loop

### Initialization

Group all pending tasks by `Repo` column into **lanes**:

```
lanes = {
  "AuthService":     { pending: [T1, T2], active: null, phase: "idle" },
  "BillingService":  { pending: [T3],     active: null, phase: "idle" },
}
```

Each lane tracks:
- `pending` — tasks not yet started (respecting dependencies)
- `active` — currently running agent (tester, developer, or reviewer)
- `phase` — `idle` | `testing` | `developing` | `reviewing`
- `worktree` / `worktree_branch` — shared worktree for the current task (orchestrator-created)
- `worktree_failed` — boolean; `true` when worktree creation failed and lane runs on feature branch directly
- `feature_head` — feature branch HEAD SHA at T(n) start (load-bearing for Step 4 fallback squash)
- `test_commit` — Tester's commit hash (failing tests); extracted from the Tester's `Commit:` field in AGENT STATUS
- `impl_commit` — Developer's commit hash (passing implementation)

### Main Loop

Repeat until all lanes are complete (no pending, active, or reviewing tasks):

#### Step 1: Launch Tester or Developer for Idle Lanes

For each lane where `phase == "idle"` and `pending` is non-empty:

1. **Check intra-repo dependencies** — pop the next task T from `pending` only if ALL
   its `depends: T<n>[, T<n>...]` Notes-column dependencies (same repo) are ✅ Done.
   Cross-repo dependencies are resolved via plan contracts, not blocking.
   If a declared dependency ID is missing from the tracker, surface as a planner error — do not advance.

2. **Update tracker**: T → 🔧 In Progress. Set `Started` in Task Metrics to the canonical UTC timestamp (see [timestamp](../context/timestamp.md)).

3. **Capture feature branch state** for the repo. Persist both values into the lane
   state — `feature_head` is load-bearing in Step 4's fallback-mode squash:

   ```bash
   REPO_PATH="<from Repo Status>"
   FEATURE_BRANCH=$(git -C "$REPO_PATH" rev-parse --abbrev-ref HEAD)
   FEATURE_HEAD=$(git -C "$REPO_PATH" rev-parse HEAD)
   ```

4. **Read the task's `test-required` flag** from the tracker's Notes column.

5. **Create the worktree** (orchestrator-side — per orchestrator-rules #3, the orchestrator handles all git operations including worktree creation).

   > Authoritative reference: [worktree-lifecycle](../context/worktree-lifecycle.md) — the canonical naming convention, retry-once policy, and `worktree_failed: true` fallback contract live in the shared file. The inline implementation below mirrors that contract for the per-task fan-out lane (per [parallel-lane](../context/parallel-lane.md)). When the shared file's contract changes, this block updates to match.

   ```bash
   UID8=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | cut -c1-8 \
          || python3 -c "import uuid; print(str(uuid.uuid4())[:8])")
   if [ -z "$UID8" ]; then
     echo "develop.md Step 1.5: UID8 generation failed — neither uuidgen nor python3 produced a value. Pause the lane and escalate to the human." >&2
     exit 1
   fi
   WORKTREE_BRANCH="worktree/<story-id>-t<n>-${UID8}"
   WORKTREE_PATH="<REPO_PATH>/../worktrees/<repo-name>-t<n>-${UID8}"
   if git -C "<REPO_PATH>" worktree add "$WORKTREE_PATH" -b "$WORKTREE_BRANCH" "<feature-branch>"; then
     WORKTREE_FAILED=false
   else
     # Retry once — the most common failure (`could not lock config file .git/config: File exists` on Windows) is transient
     if git -C "<REPO_PATH>" worktree add "$WORKTREE_PATH" -b "$WORKTREE_BRANCH" "<feature-branch>"; then
       WORKTREE_FAILED=false
     else
       WORKTREE_FAILED=true
     fi
   fi
   ```

   Store `WORKTREE_PATH` and `WORKTREE_BRANCH` in lane state immediately. The UID8 suffix on both branch and path prevents collisions when a crashed session leaves an orphan worktree on disk (see `orchestrator-rules.md` → *Worktree Reconciliation on Resume*).

**If `test-required: true` → Launch @ai-sdlc-tester (TDD path):**

Launch **@ai-sdlc-tester** with `run_in_background: true`, `name: "tester-<repo-name>"`, `mode: "auto-tdd"`:

   ```
   @ai-sdlc-tester Write failing tests for task T<n> of Story $ARGUMENTS (auto-tdd mode).
   The worktree has already been created for you — DO NOT create another one.
   Commit test code only — do NOT commit the task tracker.
   Do NOT write any production code.
   Report your commit hash in your AGENT STATUS.

   [Include LANGUAGE_CTX — omit format-cmd]
   [Include WORKTREE_CTX if WORKTREE_FAILED=false, else REPO_CTX with `worktree_failed: true`]
   [Include PATTERN_HINTS_CTX from the plan's Test Pattern References section if present]

   TEST OUTLINE FOR T<n> (from approved plan):
   <Copy the Test Outline section for this task exactly as written in the plan>

   Instructions:
   1. Implement EXACTLY the tests in the Test Outline — work in the provided worktree
      (or feature branch if `worktree_failed: true`).
   2. Run the test command. Confirm each test FAILS (red). Acceptable: assertion error or
      "type not found". NOT acceptable: compile errors in test code.
   3. Commit test code only: `#<STORY-ID> #T<n> test: <slug>` + co-author trailer.
   4. Report `Commit:` hash and red test list in AGENT STATUS.
   ```

Mark lane as `phase: "testing"`.

**If `test-required: false` → Launch @ai-sdlc-developer (direct path):**

Launch **@ai-sdlc-developer** with `run_in_background: true`, `name: "developer-<repo-name>"`, `mode: "auto"`:

   ```
   @ai-sdlc-developer Implement task T<n> for Story $ARGUMENTS.
   test-required: false — implement production code only.
   The worktree has already been created for you — DO NOT create another one.
   Commit production code only — do NOT commit the task tracker.
   Report your commit hash in your AGENT STATUS.

   [Include LANGUAGE_CTX — omit test-cmd]
   [Include WORKTREE_CTX if WORKTREE_FAILED=false, else REPO_CTX with `worktree_failed: true`]
   [Include CONTRACTS_CTX if multi-repo]
   ```

Mark lane as `phase: "developing"`.

**Launch all eligible lanes in a single message** — this enables true parallelism.

#### Step 1b: Handle Tester Completion → Launch Developer

*(Only applies to lanes in `phase: "testing"`.)*

Parse the agent's status block per [agent-response](../context/agent-response.md) — the orchestrator-side parser contract (locate header, extract fields, route on `Outcome`/`Verdict`) is the canonical reference.

**If `Outcome: SUCCESS`:**

1. Extract `Worktree`, `Worktree branch`, `Commit`, `Red tests` from Tester AGENT STATUS. Cache as `test_commit` in lane state.
2. Record `Test Written` in Task Metrics (see [timestamp](../context/timestamp.md)).
3. Launch **@ai-sdlc-developer** in the **SAME worktree** with `run_in_background: true`, `name: "developer-<repo-name>"`, `mode: "auto"`:

   ```
   @ai-sdlc-developer Implement task T<n> for Story $ARGUMENTS. Failing tests are already in the worktree.
   Make ALL failing tests pass. Do NOT modify test files — only write production code.
   Commit production code only — do NOT commit the task tracker.
   Report your worktree path, branch, and commit hash in your AGENT STATUS.

   [Include LANGUAGE_CTX — omit test-cmd]
   [Include WORKTREE_CTX, plus:]
   - Tester commit: <test_commit from lane state>
   - Red tests to turn green: <Red tests list from Tester AGENT STATUS>
   [Include CONTRACTS_CTX if multi-repo]

   1. Run the test command — confirm red tests are failing. If any are already green, halt.
   2. Implement production code until ALL tests pass and build is clean.
   3. Do NOT touch test files. If a test seems wrong, stop and flag.
   4. Commit production code only: `#<STORY-ID> #T<n> impl: <slug>` + co-author trailer.
   ```

4. Mark lane as `phase: "developing"`.

**If `Outcome: FAILED` (tester could not produce a red test):**
Report which tests couldn't be made to fail. Human decides: (a) amend Test Outline and re-invoke, or (b) mark `test-required: false`. Do NOT auto-proceed.

**If `Outcome: PARTIAL` or compile error:** Re-invoke tester with targeted fix instructions in the same worktree.

#### Step 2: Wait for Agent Completion

Wait for the next background agent to complete. Identify the lane from the agent name (`tester-<repo>`, `developer-<repo>`, `reviewer-<repo>`).

#### Step 3: Handle Developer Completion

Parse the agent's status block per [agent-response](../context/agent-response.md).

**If `Outcome: SUCCESS` or `DONE_WITH_CONCERNS`:**

1. Extract `Worktree`, `Worktree branch`, `Commit`, `Repo`, `Repo path`. Record `Build attempts` as `Build Retries`.
   **Record `Green At` only when `Build result` starts with `PASS`**; leave as `—` otherwise (reviewer-approval path stamps it). Store commit as `impl_commit`.
2. Update tracker: T(n) → 🔄 In Review.
3. Launch **@ai-sdlc-reviewer** with `run_in_background: true`, `name: "reviewer-<repo-name>"`, `mode: "auto"`:

   ```
   @ai-sdlc-reviewer Review task T<n> for Story $ARGUMENTS.

   [Include LANGUAGE_CTX — omit restore-cmd and format-cmd]
   [Include WORKTREE_CTX, plus:]
   - Developer concerns: <from Developer AGENT STATUS Concerns field, or "none">

   <IF test-required: true — include TDD CONTEXT:>
   - Tester commit: <test_commit>  Developer commit: <impl_commit>
   - Test Outline for T<n>: <copy from plan>
   Worktree contains TWO commits (Tester's red tests, then Developer's green impl) — review as one change.

   Two-phase review:
   1. SPEC COMPLIANCE (Phase A): Read plan at `ai/*-$ARGUMENTS/plan.md` (or legacy `ai/plans/*$ARGUMENTS*`),
      verify T<n> requirements. If test-required: also verify test files unchanged by Developer,
      tests match approved outline, all tests pass.
   2. CODE QUALITY (Phase B): if spec passes — run build, evaluate conventions and PR checklist.

   Label comments per `agents/reviewer/index.md`: [S<n>] spec failure, [R<n>] production quality,
   [T<n>] test quality. Suggestions as SUGGESTION severity inside [R/T]. Do NOT update the tracker.
   ```

4. Mark lane as `phase: "reviewing"`.

**If `Outcome: FAILED` and `Build attempts: 3`:** Set `Build Retries` to 3. Pause lane, report to human.

**If `Outcome: PARTIAL`:** Re-invoke developer with targeted fix instructions (same lane).

**If `Outcome: BLOCKED`:**
Present blocker to human. Special case — `Next action: "escalate to human — spec judgement: test vs impl"` (previously-green tests broke; Developer cannot edit tests, Tester cannot arbitrate): surface `Blockers` list and ask human to pick:
- **(a) Impl is wrong** — re-invoke @ai-sdlc-developer in the SAME worktree; tests untouched.
- **(b) Test needs updating** — invoke @ai-sdlc-tester in the SAME worktree (`mode: "auto-tdd"`, test-edit scope); after SUCCESS re-invoke @ai-sdlc-developer to verify build, then resume Step 3.

Do NOT auto-route — wait for human. Do not advance the lane while open.

> **Note:** `Next action: "worktree failed — retry without isolation"` is no longer reachable (orchestrator creates worktree in sub-step 5 before any agent launch). If a legacy agent reports it anyway, treat as a warning and continue. Orchestrator-side fallback contract is in [worktree-lifecycle](../context/worktree-lifecycle.md).

#### Step 4: Handle Reviewer Completion

Parse the Reviewer's status block per [agent-response](../context/agent-response.md).

**If `Verdict: APPROVED`:**

1. **Collapse the task's commits into one squashed commit on the feature branch.**
   The exact commands depend on whether the lane is in worktree mode or fallback
   mode (`worktree_failed` from lane state, set in Step 1 sub-step 5).

   **Worktree mode (`worktree_failed: false`):**

   ```bash
   REPO_PATH="<from lane>"
   git -C "$REPO_PATH" merge --squash <worktree-branch-from-developer-status>
   git -C "$REPO_PATH" commit -m "$(cat <<'EOF'
#<STORY-ID> #T<n>: <task-title-from-plan>

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
   ```
   **Fallback mode (`worktree_failed: true`):**

   No worktree branch — all agent commits landed on the feature branch. Collapse back to
   `feature_head` (from lane state, captured at sub-step 3):

   ```bash
   REPO_PATH="<from lane>"
   git -C "$REPO_PATH" reset --soft "<feature_head from lane>"
   git -C "$REPO_PATH" commit -m "$(cat <<'EOF'
#<STORY-ID> #T<n>: <task-title-from-plan>

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
   ```

   `--soft` preserves staged changes; result is byte-identical to `git merge --squash` in worktree mode.

2. **Update tracker**: T(n) → ✅ Done, Reviewer Verdict → ✅ Approved, Commit(s) → squash hash.
   Set `Completed` (see [timestamp](../context/timestamp.md)), increment `Review Rounds`.
   **`Green At` fallback**: if still `—`, stamp now (tests are definitionally green at reviewer-approval).

3. **Clean up** — worktree mode only. In fallback mode there is no worktree or
   worktree branch to remove; skip this step entirely:

   ```bash
   # Worktree mode only:
   git -C "$REPO_PATH" worktree remove "<worktree-path>" 2>/dev/null
   git -C "$REPO_PATH" branch -D "<worktree-branch>" 2>/dev/null
   ```

4. Mark lane as `phase: "idle"`. **Loop back to Step 1.** (`worktree_failed` is re-evaluated per task.)

**If `Verdict: CHANGES_REQUESTED`:**

1. **Update tracker**: T(n) Reviewer Verdict → 🔄 Changes Requested. Increment `Review Rounds`.
   Append to `## Review History`: `### T<n> · Round <N> · <timestamp>` + Reviewer comments verbatim.
   Do NOT pause — continue immediately to rework.

2. **Classify comments** per [comment-routing](../context/comment-routing.md):
   - `[R<n>]` → Developer (production code). `[T<n>]` → Tester (test code).
   - `[S<n>]` → route by file path (production → Developer, test → Tester; ambiguous → Developer).
   When both Developer- and Tester-bound comments exist, invoke Tester first.

3. **If `[T<n>]` comments:** Re-invoke **@ai-sdlc-tester** (`run_in_background: true`, `name: "tester-<repo-name>"`, `mode: "auto-tdd"`):

   ```
   @ai-sdlc-tester Address test review comments for T<n> of Story $ARGUMENTS.
   <Worktree mode:> Working in EXISTING worktree at: <worktree-path>
   <Fallback mode:> Working on feature branch <FEATURE_BRANCH> at <REPO_PATH> (worktree_failed: true).
   Do NOT modify production code — only fix test code.

   [Include LANGUAGE_CTX — omit restore-cmd and format-cmd]
   [Include WORKTREE_CTX if WORKTREE_FAILED=false, else REPO_CTX with `worktree_failed: true`]

   Test comments: [T1] ... [T2] ...
   Fix, confirm tests still red/pass as appropriate, commit, report status.
   ```

   After Tester completes, if `[R<n>]` comments also exist, invoke Developer next. Else re-launch Reviewer.

4. **If `[R<n>]` comments:** Re-invoke **@ai-sdlc-developer** (`run_in_background: true`, `name: "developer-<repo-name>"`, `mode: "auto"`):

   ```
   @ai-sdlc-developer Address review comments for T<n> of Story $ARGUMENTS.
   <Worktree mode:> Working in EXISTING worktree at: <worktree-path>
   <Fallback mode:> Working on feature branch <FEATURE_BRANCH> at <REPO_PATH> (worktree_failed: true).
   Do NOT modify test files — only fix production code.

   [Include LANGUAGE_CTX — omit test-cmd]
   [Include WORKTREE_CTX if WORKTREE_FAILED=false, else REPO_CTX with `worktree_failed: true`]

   Review comments: [R1] ... [R2] ...
   Fix, ensure all tests pass and build is clean, commit, report status.
   ```

5. Mark lane as `phase: "developing"` (or `"testing"` if only `[T<n>]`). Loop back to Step 2.

**If `Outcome: FAILED`:** Investigate. Retry if recoverable; escalate to human otherwise.

#### Step 5: Repeat

Continue until ALL lanes have no pending tasks and no active agents.

### Cross-Repo Contracts (No Blocking)

Lanes never wait on each other. For CONTRACTS_CTX: orchestrator reads `contracts.md` (if it exists) from the workflow dir and includes only the section for the active repo. Developer implements against the contract definition; reviewer verifies compliance (`[S<n>]` + `Contract: C<n>` annotation on mismatch). Phase 5 validates both sides.

For single-repo stories, CONTRACTS_CTX is omitted entirely — no cross-repo boundaries exist.

### Concurrency Rules (Non-Negotiable)

- **Within a repo**: strictly sequential — never more than one active agent per lane.
- **Across repos**: fully parallel via `run_in_background: true`.
- NEVER start T(n+1) before T(n) is reviewer-approved. NEVER squash-merge before approval.
- NEVER launch Developer on `test-required: true` before Tester commits failing tests.
- Squash-merge is synchronous (between reviewer completion and next task launch).
- Worktree mode: `git merge --squash` only — never cherry-pick or plain merge.
- Fallback mode: `git reset --soft <feature_head>` + fresh commit (see Step 4).
- Tester and Developer share the same worktree (or feature branch in fallback mode).

## Next Phase

Once ALL development tasks across ALL repos are ✅ Done, proceed to **Phase 4: Approve
Implementation** — read and execute `commands/approve-impl.md`.
