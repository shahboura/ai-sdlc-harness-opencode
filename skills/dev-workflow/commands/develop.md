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
- Task tracker exists at `ai/<YYYY-MM-DD>-<work-item-id>/tracker.md` (new — see [workflow-paths](../context/workflow-paths.md)) OR `ai/tasks/*.md` (legacy — supported during migration window).
- Pre-flight complete — feature branches exist in every repo named in the tracker's `## Repo Status` section, and the plan commit has landed (single-repo workspace-is-git-repo case) or is deferred to Phase 6 (workspace-not-a-git-repo case).
- If in direct phase mode, verify:
  ```bash
  # Tracker + plan presence — prefer new layout, fall back to legacy
  ls ai/*-${STORY_ID}/tracker.md 2>/dev/null || ls ai/tasks/*${STORY_ID}* 2>/dev/null  # tracker
  ls ai/*-${STORY_ID}/plan.md    2>/dev/null || ls ai/plans/*${STORY_ID}* 2>/dev/null  # plan
  ```

## Pre-Flight

Before starting, read the tracker for the Story ID. Prefer `ai/*-${STORY_ID}/tracker.md` (new canonical layout per [workflow-paths](../context/workflow-paths.md)); fall back to `ai/tasks/*${STORY_ID}*.md` (legacy).

**Read repo configuration:**
```bash
cat .claude/context/repos-paths.md
cat .claude/context/language-config.md
```

Parse the tracker's **Repo Status** section to build a map of
`repo-name → { local-path, feature-branch, default-branch }`.
Also build a language map: `repo-name → { language, build-cmd, restore-cmd, format-cmd, build-adapter-path }`.
Conventions are always at `.claude/context/conventions.md` (not per-repo).
If no Repo Status section exists (legacy tracker), treat all tasks as a single lane keyed on the repo from the story metadata.

**Record metric:** If `Development started` is still `—`, set it to the canonical UTC timestamp.
> Authoritative reference: [timestamp](../context/timestamp.md)

## Execution Model

### Prompt Context Templates

Every agent launch includes standard context blocks: **LANGUAGE_CTX**, **REPO_CTX**, **WORKTREE_CTX**, and **CONTRACTS_CTX**. The full schema for each, including which fields to include or omit per agent role, lives in [`../context/prompt-templates.md`](../context/prompt-templates.md). The steps below reference these templates by name — do not retype them inline.

### Detect Mode

Read the tracker's `Repo` column to build the lane map. Every task has a `Repo` value — single-repo stories have one repo for all tasks, multi-repo stories have several. Single-repo stories run with exactly one lane; all the same steps apply, no cross-repo parallelism needed.

---

## Execution Loop

### Initialization

Group all pending tasks by their `Repo` column into **lanes**:

```
lanes = {
  "AuthService":     { pending: [T1, T2], active: null, phase: "idle" },
  "BillingService":  { pending: [T3],     active: null, phase: "idle" },
}
```

Each lane tracks:
- `pending` — ordered list of tasks not yet started (respecting dependencies)
- `active` — the currently running agent (tester, developer, or reviewer), if any
- `phase` — `idle` | `testing` | `developing` | `reviewing`
- `worktree` / `worktree_branch` — shared worktree for the current task (created by the orchestrator in Step 1 sub-step 5)
- `worktree_failed` — boolean; `true` when worktree creation failed twice and the lane is on the feature branch directly
- `feature_head` — the feature branch's HEAD SHA at the moment T(n) started (captured in Step 1 sub-step 3). Used by Step 4's fallback-mode squash to collapse the task's commits back to one — without it, there is no worktree branch to merge from.
- `test_commit` — commit hash extracted from the Tester's `Commit:` field (failing tests). Internal lane-state variable name; the source field on the block is `Commit:` per `agents/shared/status-schema.md`.
- `impl_commit` — commit hash from the Developer AGENT STATUS (passing implementation)

### Main Loop

Repeat until all lanes are complete (no pending, active, or reviewing tasks):

#### Step 1: Launch Tester or Developer for Idle Lanes

For each lane where `phase == "idle"` and `pending` is non-empty:

1. **Check intra-repo dependencies** — pop the next task T from `pending`, but only if ALL
   its dependencies **within the same repo** are ✅ Done. (Cross-repo dependencies do not
   exist — they are resolved via contracts defined in the plan.)

   Dependencies are declared by the Planner as a `depends: T<n>[, T<n>...]` token in the
   task row's **Notes** column (canonical format documented in
   `skills/plan-generator/SKILL.md` → *Dependency notation*). To resolve:
   - Read the candidate task's Notes cell.
   - Match the regex `depends:\s*(T[A-Za-z0-9-]+(?:\s*,\s*T[A-Za-z0-9-]+)*)`.
   - If matched, split the captured group on commas and trim whitespace — that is the
     dependency list. Every listed Task ID must be ✅ Done in the **same repo** before this
     task is eligible.
   - If no `depends:` token is present, the task has no intra-repo dependencies.
   - If the captured Task ID does not appear in this repo's tracker rows, treat it as a
     planner error: leave the task in `pending`, surface to human, and do not advance the lane.

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

   Store `WORKTREE_PATH` and `WORKTREE_BRANCH` in the lane state immediately so a resumption can find them even before the agent reports. Doing creation here (not inside the agent) eliminates the pre-worktree stall mode — if creation succeeds, the worktree is guaranteed to exist on disk before any agent launches; if it fails, the orchestrator picks the fallback deterministically.

   Both the branch name and the path carry the same `${UID8}` suffix. The path needs the UID8 just like the branch does — without it, a session that crashed mid-task and left a worktree at `<REPO_PATH>/../worktrees/<repo-name>-t<n>/` on disk would collide with the next resume's `git worktree add` attempt (the directory already exists, so the add aborts). Carrying the UID8 in the path makes a fresh resume always succeed even when the previous attempt's worktree is still there; the orphan is then surfaced and cleaned by the reconciliation flow in `orchestrator-rules.md` → *Worktree Reconciliation on Resume*.

**If `test-required: true` → Launch @ai-sdlc-tester (TDD path):**

Launch **@ai-sdlc-tester** with `run_in_background: true`, `name: "tester-<repo-name>"`, and `mode: "auto-tdd"`:

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
   1. Implement EXACTLY the tests listed in the Test Outline above — no more, no less.
      Work inside the provided worktree (or directly on the feature branch if
      `worktree_failed: true`).
   2. Run the test command. Confirm each new test FAILS (red). Acceptable failure: assertion
      error or "type/method not found" (expected — impl doesn't exist yet). NOT acceptable:
      compile errors in test code itself (wrong syntax, wrong test framework usage).
   3. Commit with co-author trailer — test code only:
      ```
      #<STORY-ID> #T<n> test: <slug>

      Co-Authored-By: Claude Code <noreply@anthropic.com>
      ```
   4. Report `Commit:` hash and the list of red tests in AGENT STATUS.
   ```

Mark lane as `phase: "testing"`.

**If `test-required: false` → Launch @ai-sdlc-developer (direct path):**

Launch **@ai-sdlc-developer** with `run_in_background: true`, `name: "developer-<repo-name>"`, and `mode: "auto"`:

   ```
   @ai-sdlc-developer Implement task T<n> for Story $ARGUMENTS.
   This task is test-required: false — no pre-written tests exist. Implement production code only.
   The worktree has already been created for you — DO NOT create another one.
   Commit production code only — do NOT commit the task tracker.
   Report your commit hash in your AGENT STATUS.

   [Include LANGUAGE_CTX — omit test-cmd]
   [Include WORKTREE_CTX if WORKTREE_FAILED=false, else REPO_CTX with `worktree_failed: true`]
   [Include CONTRACTS_CTX if multi-repo]

   Work inside the provided worktree (or directly on the feature branch if
   `worktree_failed: true`).
   ```

Mark lane as `phase: "developing"`.

**Launch all eligible lanes in a single message** — this enables true parallelism.

#### Step 1b: Handle Tester Completion → Launch Developer

*(Only applies to lanes in `phase: "testing"`.)*

Parse the agent's status block per [agent-response](../context/agent-response.md) — the orchestrator-side parser contract (locate header, extract fields, route on `Outcome`/`Verdict`) is the canonical reference.

**If `Outcome: SUCCESS`:**

1. Extract `Worktree`, `Worktree branch`, `Commit` (Tester's), `Red tests` from Tester AGENT STATUS. Cache the commit hash as `test_commit` in lane state.
2. Record `Test Written` in Task Metrics using the canonical UTC timestamp (see [timestamp](../context/timestamp.md)).
3. Launch **@ai-sdlc-developer** in the **SAME worktree** with `run_in_background: true`, `name: "developer-<repo-name>"`, and `mode: "auto"`:

   ```
   @ai-sdlc-developer Implement task T<n> for Story $ARGUMENTS. Failing tests are already in the worktree.
   Your job: make ALL failing tests pass. Do NOT modify the test files — only write production code.
   Commit production code only — do NOT commit the task tracker.
   Report your worktree path, branch, and commit hash in your AGENT STATUS.

   [Include LANGUAGE_CTX — omit test-cmd]
   [Include WORKTREE_CTX, plus these additional fields:]
   - Tester commit: <Commit from Tester AGENT STATUS (cached as test_commit in lane state)>
   - Red tests to turn green: <Red tests list from Tester AGENT STATUS>
   [Include CONTRACTS_CTX if multi-repo]

   Instructions:
   1. Start by running the test command. Confirm the red tests are indeed failing.
      If any are already green, halt and flag — do not continue.
   2. Implement production code until ALL tests pass and build is clean (zero warnings).
   3. Do NOT touch any test file. If you believe a test is wrong, stop and flag to orchestrator.
   4. Commit with co-author trailer — production code only:
      ```
      #<STORY-ID> #T<n> impl: <slug>

      Co-Authored-By: Claude Code <noreply@anthropic.com>
      ```
   ```

4. Mark lane as `phase: "developing"`.

**If `Outcome: FAILED` (tester could not produce a red test from the outline):**

- Report to human: describe which test name(s) could not be made to fail and why.
- Human decides: (a) amend the Test Outline in the plan and re-invoke tester, or (b) mark the task `test-required: false` and proceed directly with the developer.
- Do NOT auto-proceed to the developer.

**If `Outcome: PARTIAL` or compile error in test code:**
- Re-invoke tester with targeted fix instructions in the same worktree.

#### Step 2: Wait for Agent Completion

Wait for the next background agent to complete (notification arrives automatically).
Identify which lane it belongs to from the agent name (`tester-<repo>`, `developer-<repo>`, or `reviewer-<repo>`).

#### Step 3: Handle Developer Completion

Parse the agent's status block per [agent-response](../context/agent-response.md).

**If `Outcome: SUCCESS` or `DONE_WITH_CONCERNS`:**

1. Extract `Worktree`, `Worktree branch`, `Commit`, `Repo`, `Repo path` fields.
   Record `Build attempts` as T(n) `Build Retries` in Task Metrics.
   **Record `Green At` ONLY when the developer's `Build result` starts with `PASS`** (full form: `PASS (0 warnings)`). If `Build result` reports `FAIL` — or the field is missing — leave `Green At` as `—`; the reviewer-approval path below will stamp it once the reviewer confirms tests actually pass. This prevents the failure mode where the developer reports `Outcome: SUCCESS` but tests were still red (the metric should reflect when tests **truly** turned green, not when the agent first emitted SUCCESS). Use the canonical UTC timestamp (see [timestamp](../context/timestamp.md)) when stamping.
   Store developer commit hash as `impl_commit` in the lane state.
2. Update tracker: T(n) → 🔄 In Review.
3. Launch **@ai-sdlc-reviewer** with `run_in_background: true`, `name: "reviewer-<repo-name>"`, and `mode: "auto"`:

   ```
   @ai-sdlc-reviewer Review task T<n> for Story $ARGUMENTS.

   [Include LANGUAGE_CTX — omit restore-cmd and format-cmd]
   [Include WORKTREE_CTX, plus:]
   - Developer concerns: <from Developer AGENT STATUS Concerns field, or "none">

   <IF test-required: true — include the following TDD context:>
   TDD CONTEXT:
   - Tester commit (failing tests): <test_commit from lane state>
   - Developer commit (implementation): <impl_commit from lane state>
   - Test Outline for T<n>: <copy from plan>
   This worktree contains TWO commits: first the Tester's (red tests), then the Developer's
   (green implementation). Review them together as one logical change.

   Perform your two-phase review:
   1. SPEC COMPLIANCE (Phase A): Read the plan at `ai/*-$ARGUMENTS/plan.md` (new canonical layout per workflow-paths.md) OR `ai/plans/*$ARGUMENTS*` (legacy fallback), find task T<n>,
      and verify every requirement is implemented. If the developer flagged concerns, scrutinize
      those areas especially.
      <IF test-required: true — also verify:>
      - The test files were NOT modified by the Developer commit (Tester owns tests).
      - The tests present in the worktree match the approved Test Outline for T<n>.
      - All tests pass (run the test command).
   2. CODE QUALITY (Phase B): Only if spec passes — run the build command at the worktree
      path, evaluate language conventions and PR checklist.

   Produce your structured review verdict. Label comments per `agents/reviewer/index.md`:
   - [S<n>] — spec compliance failure (Phase A). Place the comment against the file that needs
     to change to satisfy the plan — production or test.
   - [R<n>] — quality issue in production code (Phase B) — routed to the Developer.
   - [T<n>] — quality issue in test code (Phase B) — routed to the Tester.
   Suggestions are NOT a separate prefix — emit them as `SUGGESTION` severity inside [R<n>] or
   [T<n>]. Do NOT update the tracker — the orchestrator handles that.
   Return your full review report.
   ```

4. Mark lane as `phase: "reviewing"`.

**If `Outcome: FAILED` and `Build attempts: 3`:**
- Set T(n) `Build Retries` to 3. Pause lane, report build failure to human.

**If `Outcome: PARTIAL`:**
- Re-invoke developer with targeted fix instructions (same lane, same background pattern).

**If `Outcome: BLOCKED`:**
- Present blocker to human for resolution.
- **Special case — `Next action: "escalate to human — spec judgement: test vs impl"`:**
  the Developer detected that one or more **previously-green tests** broke as a side effect
  of T(n)'s implementation. This is the cannot-self-resolve path defined in
  `agents/developer/index.md` → *Broken Pre-Existing Tests*. The Developer cannot edit tests;
  the Tester cannot decide whether the impl or the test is wrong. Surface the `Blockers`
  list to the human verbatim and ask them to pick one branch:
  - **(a) Impl is wrong** — re-invoke @ai-sdlc-developer in the SAME worktree with the broken tests
    as focused fix instructions; tests stay untouched.
  - **(b) Test needs updating** — invoke @ai-sdlc-tester in the SAME worktree with `mode: "auto-tdd"`,
    pointing at the specific tests to update (note: scope is test-edit, not new test
    authoring); after tester SUCCESS, re-invoke @ai-sdlc-developer to verify the worktree builds and
    all tests are green, then resume the normal review path (Step 3 onwards).

  Do NOT auto-route to either agent — wait for the human's selection. Do not advance the
  lane while the question is open.

> **Note:** The agent-side `Next action: "worktree failed — retry without isolation"`
> branch from earlier versions is no longer reachable — the orchestrator creates
> the worktree in Step 1 (sub-step 5) before any agent launch, so worktree-creation
> failures are handled deterministically before the agent runs. If an agent reports
> this status anyway (a legacy or out-of-date agent definition), treat it as a
> warning and proceed; the worktree should already exist or `worktree_failed: true`
> should already be in the prompt.
>
> **Layering vs `worktree-lifecycle.md`**: this clause is the **agent-side** rule
> (legacy/stale agent re-reporting a failure the orchestrator already absorbed in
> sub-step 5). The **orchestrator-side** rule lives in
> [worktree-lifecycle](../context/worktree-lifecycle.md) → *Fallback contract*:
> when the orchestrator's own worktree-add fails twice, it sets `worktree_failed:
> true` and falls back to direct-branch mode; only if the direct-branch fallback
> itself fails does the workflow route to R for recovery. The two rules describe
> the same failure mode at different layers and are not contradictory.

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
   The squash captures both the Tester's failing-test commit and the Developer's implementation as one merged commit on the feature branch.

   **Fallback mode (`worktree_failed: true`):**

   No worktree branch exists — every agent commit (test, impl, and any rework
   commits) landed directly on the feature branch. Collapse them back to
   `feature_head` (captured at Step 1 sub-step 3) and write the same squash commit:

   ```bash
   REPO_PATH="<from lane>"
   git -C "$REPO_PATH" reset --soft "<feature_head from lane>"
   git -C "$REPO_PATH" commit -m "$(cat <<'EOF'
#<STORY-ID> #T<n>: <task-title-from-plan>

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
   ```

   The `--soft` reset keeps every staged change identical to what the agents
   produced; only the commit graph is rewritten. The result on the feature
   branch is byte-identical to what `git merge --squash` would have produced
   in worktree mode.

2. **Update tracker**: T(n) Status → ✅ Done, Reviewer Verdict → ✅ Approved, Commit(s) → squash-merge hash.
   Set `Completed` in Task Metrics to the canonical UTC timestamp (see [timestamp](../context/timestamp.md)), increment `Review Rounds` by 1.
   **`Green At` fallback stamp**: if `Green At` is still `—` (i.e., the developer's earlier `Build result` was FAIL or the field was missing at Step 3), stamp it **now** using the same canonical UTC timestamp. By reviewer-approval time tests are definitionally green (the reviewer verified them in Step A), so the metric becomes correct. Do nothing if `Green At` is already set.

3. **Clean up** — worktree mode only. In fallback mode there is no worktree or
   worktree branch to remove; skip this step entirely:

   ```bash
   # Worktree mode only:
   git -C "$REPO_PATH" worktree remove "<worktree-path>" 2>/dev/null
   git -C "$REPO_PATH" branch -D "<worktree-branch>" 2>/dev/null
   ```

4. Mark lane as `phase: "idle"`. **Loop back to Step 1** — this lane can now pick up
   its next pending task. (Fallback mode persists for the next task too if Step 1
   sub-step 5 fails again — `worktree_failed` is re-evaluated per task, not per lane.)

**If `Verdict: CHANGES_REQUESTED`:**

1. **Update tracker**: T(n) Reviewer Verdict → 🔄 Changes Requested. Increment `Review Rounds` by 1.
   Append an entry to the `## Review History` section of the tracker:

   ```
   ### T<n> · Round <Review Rounds> · <canonical UTC timestamp — see timestamp.md>
   **Repo:** <repo-name>
   <paste the full Review comments field from the Reviewer AGENT STATUS verbatim>
   ```

   Do NOT pause the workflow or notify the human — continue immediately to rework.

2. **Classify review comments** by prefix per [comment-routing](../context/comment-routing.md) — the shared file is the canonical `[S]/[R]/[T]` routing source. Project-internal extensions used by this command's numbered variants:
   - `[R<n>]` — production-code change → route to **Developer** (per comment-routing's `[R] → Developer` default).
   - `[T<n>]` — test-code change → route to **Tester** (per `[T] → Tester`).
   - `[S<n>]` — spec compliance failure → route by the **file path inside the comment**: production file → Developer, test file → Tester. If a single `[S<n>]` mentions both (e.g. plan requires both impl and test changes), route to whichever agent owns the file listed in the comment; if ambiguous, default to the Developer and include the comment verbatim so they can flag it.

   When both Developer- and Tester-bound comments exist in the same round, invoke the Tester first (so the failing/refined tests are in the worktree) and then the Developer.

3. **If there are `[T<n>]` comments (test rework needed):**
   Re-invoke **@ai-sdlc-tester** with `run_in_background: true`, `name: "tester-<repo-name>"`, `mode: "auto-tdd"`. Use the same workspace context the lane was launched with (worktree mode → same worktree; fallback mode → same feature branch — there is no worktree to share):

   ```
   @ai-sdlc-tester Address the following test review comments for task T<n> of Story $ARGUMENTS.
   <Worktree mode:>      You are working in the EXISTING worktree at: <worktree-path>
   <Fallback mode:>      You are working directly on feature branch <FEATURE_BRANCH> at <REPO_PATH> (worktree_failed: true).
   Do NOT modify production code — only fix the test code.

   [Include LANGUAGE_CTX — omit restore-cmd and format-cmd]
   [Include WORKTREE_CTX if WORKTREE_FAILED=false, else REPO_CTX with `worktree_failed: true`]

   Test review comments to address:
   [T1] description...
   [T2] description...

   Fix each test issue, confirm tests are still red (if impl is being reworked) or still pass
   (if only test style/naming is being fixed), commit, and report updated status.
   ```

   After Tester completes, if `[R<n>]` comments also exist, invoke the Developer next.
   Otherwise, proceed directly to re-launch Reviewer.

4. **If there are `[R<n>]` comments (production code changes needed):**
   Re-invoke **@ai-sdlc-developer** with `run_in_background: true`, `name: "developer-<repo-name>"`, `mode: "auto"`. Same workspace-context rule as the Tester rework above:

   ```
   @ai-sdlc-developer Address the following review comments for task T<n> of Story $ARGUMENTS.
   <Worktree mode:>      You are working in the EXISTING worktree at: <worktree-path>
   <Fallback mode:>      You are working directly on feature branch <FEATURE_BRANCH> at <REPO_PATH> (worktree_failed: true).
   Do NOT modify the test files — only fix production code.

   [Include LANGUAGE_CTX — omit test-cmd]
   [Include WORKTREE_CTX if WORKTREE_FAILED=false, else REPO_CTX with `worktree_failed: true`]

   Review comments to address:
   [R1] description...
   [R2] description...

   Fix each issue, ensure all tests pass and the build is clean, commit, and report updated status.
   ```

5. Mark lane as `phase: "developing"` (or `"testing"` if only `[T<n>]` comments). Loop back to Step 2.

**If `Outcome: FAILED`:**
- Investigate. If recoverable, retry review. If not, escalate to human.

#### Step 5: Repeat

Continue the main loop until ALL lanes have no pending tasks and no active agents.

### Cross-Repo Contracts (No Blocking)

Repo lanes **never wait on each other**. Cross-repo boundaries (API calls, Service Bus
messages, shared DTOs) are resolved via **contracts** defined by the planner in Phase 2
at `ai/<workflow-dir>/contracts.md` (see [workflow-paths](../context/workflow-paths.md)).

- The orchestrator reads `contracts.md` (if it exists — multi-repo stories with cross-repo
  boundaries) and includes only the contracts where the developer's repo is Producer or
  Consumer in the CONTRACTS_CTX block (as shown in Step 1 above). On single-repo stories,
  the file is absent and CONTRACTS_CTX is omitted entirely.
- The developer implements **against** the agreed contract — the other repo's implementation
  does not need to exist yet.
- The reviewer verifies contract compliance: producer matches the contract Definition,
  consumer codes against the same Definition. A mismatch is an `[S<n>]` finding with a
  `Contract: C<n>` annotation per `agents/reviewer/index.md`.
- Integration tests in Phase 5 validate both sides of each contract.

### Concurrency Rules (Non-Negotiable)

- **Within a repo**: strictly sequential. A lane NEVER has more than one agent at a time.
- **Across repos**: fully parallel. Multiple lanes can have active agents simultaneously.
- **NEVER start T(n+1) in a lane before T(n) is approved by the reviewer.**
- **NEVER squash-merge before the reviewer approves.**
- **NEVER launch the Developer on a `test-required: true` task before the Tester commits failing tests.**
- **Squash-merge is synchronous** — the orchestrator does it between reviewer completion
  and the next task launch. It requires git commands in the specific repo directory.
- **ALWAYS use `git merge --squash` in worktree mode** — never `git cherry-pick` or regular `git merge`. In fallback mode (`worktree_failed: true`), the squash is done with `git reset --soft <feature_head>` followed by a fresh commit — see Step 4 APPROVED branch for the exact commands. Never edit the tree manually to "fake" a squash.
- **Tester and Developer share the same worktree** for each `test-required: true` task — the
  orchestrator passes the worktree path from the Tester's AGENT STATUS to the Developer. In fallback mode they share the feature branch instead; the Tester's commits land on the branch and the Developer picks them up at branch HEAD.

## Next Phase

Once ALL development tasks across ALL repos are ✅ Done, proceed to **Phase 4: Approve
Implementation** — read and execute `commands/approve-impl.md`.
