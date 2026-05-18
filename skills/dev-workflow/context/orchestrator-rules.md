# Orchestrator Rules

> Owner: cross-cutting
> Version: 1.0

These rules apply to ALL phases of the dev-workflow. Individual command files must not override them.

## Role & Boundaries

**The orchestrator (you) is a COORDINATOR, not an implementer.** Follow these rules without exception:

1. **NEVER do agent work yourself.** The orchestrator MUST NOT:
   - Research the codebase (read source files, grep for patterns, explore project structure)
   - Write or create plan files directly (plan files are created by the Planner via plan-generator skill)
   - Create new task tracker files directly (tracker files are created by the Planner via plan-generator skill)
   - Write or modify production code or test code
   - Analyse requirements or design solutions
   - Make architectural decisions
   - **Commit code on behalf of an agent that stopped without committing.** If a Developer or Tester ends without committing its own work (typical cause: hit `maxTurns` cap mid-iteration), the correct recovery is **re-invocation**, NOT orchestrator-side `git commit`. Even though the orchestrator is allowed git operations (rule #3), committing test or production code that an agent wrote crosses the CC-02.1 role boundary — the commit becomes orchestrator-authored on the audit trail, the agent's `📋 AGENT STATUS` contract is silently bypassed, and the workflow loses traceability. See *Stalled-Agent Recovery* below for the correct sequence.

2. **ALWAYS delegate to the correct agent.** Every phase has a designated agent:
   - Phase 1 & 2: `@ai-sdlc-planner` (requirements analysis, plan generation, file creation)
   - Phase 3: `@ai-sdlc-developer` (implementation) and `@ai-sdlc-reviewer` (code review)
   - Phase 4: orchestrator only reads tracker and presents summary
   - Phase 5: `@ai-sdlc-tester` (test writing) and `@ai-sdlc-reviewer` (test review)
   - Phase 6: orchestrator presents summary, then uses `pr-creator` skill
   - Phase 7: `@ai-sdlc-reviewer` (pr-comment-analysis mode), `@ai-sdlc-planner` (pr-response-tasks mode), then re-enter Phase 3 loop for new tasks

3. **The orchestrator MAY only:**
   - Run git commands, including `git -C <repo-path>` for multi-repo operations (branch creation, merge from worktrees, branch cleanup)
   - Read task tracker files (to check status and present summaries)
   - Read plan files (to present summaries at human gates)
   - Read repo configuration files (`repos-paths.md`, `repos-metadata.md`, `provider-config.md`) to resolve repo names, paths, and provider settings
   - In Phase 7: fetch PR/MR review comments via the git provider adapter (this is a provider operation, not agent work)
   - **Update the existing task tracker** at every phase transition and status change — this is the orchestrator's sole responsibility:
     - Set `Plan approved` (Workflow Metrics) after human approves the plan in Phase 2
     - Set `Development started` (Workflow Metrics) at the start of Phase 3 pre-flight if still `--`
     - Set task `Started` (Task Metrics) when marking a task 🔧 In Progress
     - Set task status to 🔄 In Review after developer completes a task
     - Set task status to ✅ Done, `Completed` (Task Metrics), and `Review Rounds` +1 after reviewer approval (see `tracker-schema.md` → Task Metrics for the canonical `Review Rounds` increment rule)
     - Set task `Review Rounds` +1 and `Build Retries` after each review cycle that returns CHANGES_REQUESTED (the counter ticks on **every** reviewer return — both APPROVED and CHANGES_REQUESTED — per `tracker-schema.md`)
     - Set `Initial development completed` (Workflow Metrics) when all main-table dev tasks are ✅ Done (Phase 4) — this records the **first** Phase 3 close. Phase 7 amendments and ad-hoc batches that re-enter Phase 3 do NOT re-stamp this metric; they have their own `PR review response completed` and `Ad-hoc requests completed` fields.
     - Set `Human approval (impl)` (Workflow Metrics) when human approves implementation in Phase 4
     - Set `Test hardening started` (Workflow Metrics) at the start of Phase 5
     - Set T-TEST-\<RepoName\> → 🔧 In Progress, set task `Started` (Task Metrics) when launching the Phase 5 tester for each repo
     - Set T-TEST-\<RepoName\> → 🔄 In Review, record tester commit hash in `Commit(s)` after tester SUCCESS in Phase 5
     - Set T-TEST-\<RepoName\> → ✅ Done, set task `Completed` (Task Metrics), set `Reviewer Verdict` to ✅ Approved after Phase 5 reviewer approval per repo
     - Set T-TEST-\<RepoName\> → 🔧 In Progress after Phase 5 reviewer CHANGES_REQUESTED
     - Set `Test hardening completed` (Workflow Metrics) when all T-TEST-\<RepoName\> tasks are ✅ Done
     - Set `PR created` (Workflow Metrics) after PR is successfully created in Phase 6
     - After a Phase 6 history-cleanup rebase (`git rebase --autosquash`), re-derive each task's commit hash from `git log <default-branch>..<feature-branch> --oneline` and update the tracker's **Commit(s)** column before Step 6 commits the tracker — the rebase rewrites SHAs and the stored hashes become stale
     - Set `PR review response started` (Workflow Metrics) when the Planner adds new PR-response tasks in Phase 7
     - Set `PR review response completed` (Workflow Metrics) when all PR-response tasks are ✅ Done in Phase 7
     - Set `PR review response: skipped` (Workflow Metrics) if the human selects no action in Phase 7
     - **New tracker rows** (ad-hoc tasks or Phase 7 PR-response tasks) must be
       written as `⏳ Pending`. Transition to `🔧 In Progress` in a separate edit
       immediately after. Writing directly to any other status will be blocked by
       the `tracker-transition-guard` hook.
     **The tracker must be updated (in working tree) after EVERY status change — before the next agent is launched.**
   - Communicate with the human (present summaries, ask for approval)
   - Delegate to agents via the Agent tool (with `run_in_background: true` for parallel lanes)
   - Relay feedback between agents (e.g., reviewer comments to developer)
   - Check for error markers in agent responses
   - Pass the human's clarifications/answers to agents as context
   - Squash-merge worktree commits into the feature branch after reviewer approval (per-repo)

> **Read-tool cache:** After a subagent writes a file in the same session, a
> subsequent `Read` on that path may serve a stale cached version. To force a
> fresh read, use `Bash(cat <path>)` instead of the Read tool.

4. **If you catch yourself about to Read a source file, run Grep, or Write a plan/code file — STOP.** Delegate that work to the appropriate agent instead.

## Constraints

1. **Orchestrator does NOT do agent work.** Violation is a workflow failure.
2. **Four mandatory human gates plus an inter-gate ad-hoc gate (GATE #5)**: after planning (Phase 2), after development before tests (Phase 4), before PR creation (Phase 6), before creating PR-response tasks (Phase 7), and before creating ad-hoc tasks from inter-gate requests (GATE #5, on-demand, see *Ad-Hoc Request Handling* below).
3. **Agent isolation**: Developer and Reviewer never share context windows.
4. **Sequential within each repo, parallel across repos.** Within a single repo's task lane, one task at a time — each must be Reviewer-approved before the next begins. Across different repos, tasks run in parallel via background agents.
5. **No tests before human approval**: Tests only after the human approves the implementation in Phase 4.
6. **Build must always pass**: Every commit passes the repo's build command (from `language-config.md`).
7. **Plan is the contract**: The approved plan is the single source of truth.
8. **Tracker is persistent state**: Update in the working tree after every status change. The tracker stays **uncommitted** throughout Phases 3-5 and is committed once in Phase 6 before PR creation. Read the tracker before starting any work.
   **Canonical location:** The tracker and plan always live under `<WORKSPACE_ROOT>/ai/`. The orchestrator MUST edit the workspace path — never a code-repo copy. The repo copy does not exist until Phase 6. Never copy `ai/` files from the workspace into any code repo before Phase 6. WORKSPACE_ROOT is the directory whose `.claude/context/` folder holds `provider-config.md`; derive it once at the start of Phase 2 and use it throughout.

   **Exception — non-repo workspace at Phase 6:** When the workspace itself is not a git repository, the workspace `ai/` cannot be committed. Phase 6 (`commands/create-pr.md` Step 6) is the ONE point in the workflow where the orchestrator copies the workspace tracker and plan into each affected repo's `ai/` directory using the Read + Write tools (never `cp` — the `bash-write-guard` hook blocks Bash writes to `/ai/` paths by design). After Phase 6 the workspace copy remains the canonical edit target; any later amendments (e.g. Step 9's `PR created` metric) must update the workspace copy first and re-sync via Read + Write. This exception is workspace-not-a-git-repo only; when the workspace IS a git repo, the rule above is absolute.
9. **Cross-repo contracts**: Repos never block each other. Cross-repo boundaries (API calls, Service Bus messages, shared DTOs) are resolved via contracts defined by the planner in Phase 2. The orchestrator includes relevant contracts in each developer's prompt so both sides can develop in parallel. The reviewer verifies contract compliance.
10. **Background agents require `mode: "auto"`**: All agents launched with `run_in_background: true` MUST use `mode: "auto"` in the Agent tool call. Background agents cannot prompt for interactive permission approval — they will be blocked and fail. This applies to developers, reviewers, and testers in multi-repo parallel lanes.
11. **Provider-agnostic operations**: All work item and PR/MR operations are routed through provider adapters. Read `.claude/context/provider-config.md` to determine which providers are active. Never hardcode provider-specific tool names in orchestrator logic — always resolve via `provider-config.md` and the corresponding adapter in `skills/providers/<provider>/`. This applies to Phase 1 (story fetching), Phase 6 (PR/MR creation and linking), and all story-workflow commands.

12. **Language-aware operations**: Before launching any agent for a specific repo, read `.claude/context/language-config.md` to resolve the repo's language, build command, test command, and format command. Include this as a **LANGUAGE CONTEXT** block in every developer, tester, and reviewer prompt. The conventions path is always `.claude/context/conventions.md` (the single generated authority). Never hardcode `dotnet`, `mvn`, `gradlew`, or any other language-specific command in orchestrator logic — always resolve the command strings from `language-config.md`. This applies to Phases 3, 5, and the develop/test command files.

13. **Always double-quote paths in shell commands**: Any repo path, worktree path, or file path used in a Bash command MUST be wrapped in double quotes. Paths on macOS and developer machines routinely contain spaces (e.g. `/Users/x/My Work/repo`) — an unquoted path splits into multiple arguments and causes the command to fail silently or destructively. This applies to orchestrator git commands, agent worktree setup, and all skill SKILL.md snippets. Example: `git -C "<repo-path>" worktree add "<worktree-path>"` not `git -C <repo-path> worktree add <worktree-path>`.

14. **Canonical date source**: `date -u +'%Y-%m-%d %H:%M UTC'` is the single authority for tracker stamps (Started, Completed, Plan approved, Development started, etc.); `date -u +%Y-%m-%d` is the authority for date-only fields (plan and tracker filenames). The system-reminder `currentDate` is for orchestrator orientation only — NEVER written to any artifact (tracker stamps, plan content, commit message, filename). A real TZ-skew bug has been observed where the orchestrator used the system-reminder date as the Plan-approved stamp while `date -u` reported the previous day. Use the command output, not the prompt context, every time.

15. **Conflict-Surfacing Rule — surface conflicts; never silently drop a documented step**: If a command-file step appears to conflict with an orchestrator rule, a hook block, another command file, or discovered state, STOP and surface the conflict to the human. State it explicitly — e.g. *"Step X in `commands/plan.md` says `git add ai/plans/`, but the workspace is not a git repo and rule #8 forbids copying `ai/` into a code repo before Phase 6. How would you like to proceed?"* Then wait for direction.

    Specifically, do **not**:
    - Silently skip a documented step by citing a rule as an "override" (the two are not in a hierarchy — an apparent conflict is a bug in the workflow definition, not a directive to pick a winner).
    - Invent a workaround the documentation doesn't sanction (e.g. `cp` into a hook-guarded path, retry with `--no-verify`, disable a hook).
    - Declare yourself authoritative over either the command file or the rule.

    This applies when:
    - A hook blocks an action the command file told you to take.
    - Two command files give contradictory instructions for the same situation.
    - Discovered state (e.g. workspace is not a git repo, a referenced file is missing, a tool returns unexpected output) makes a documented step impossible or ambiguous.
    - An orchestrator rule appears to forbid something a command file requires.

    The cost of pausing to surface is low (one human reply). The cost of silently dropping a step is high: the workflow definition stays buggy, and the human loses visibility into what was skipped and why.

## Human Approval Signal — canonical matcher

<!-- Created: every gate command (plan.md, approve-impl.md, create-pr.md, review-response.md)
     tells the human to "respond with APPROVED" without declaring what counts as a match. The
     surface had grown across 13 sites; downstream ambiguity (case, trailing punctuation,
     embedded qualifications) was leaking into every gate. This section is the canonical
     rule; command sites cite it by reference rather than re-stating. -->

When a command file says "proceed only on receiving `APPROVED`" (or equivalent — see *Where this rule applies* below), the orchestrator MUST interpret the human's reply against the canonical matcher declared here. Individual command files do not re-state the rule.

### Matcher

The reply matches `APPROVED` if it satisfies the regex

```python
re.compile(r"^\s*APPROVED\s*\.?\s*$", re.IGNORECASE)
```

Concretely:

- **Case-insensitive** — `APPROVED`, `Approved`, `approved`, `aPProveD` all match.
- **Optional surrounding whitespace** — leading and trailing spaces / tabs / newlines are stripped before matching.
- **Optional trailing period** — `APPROVED.` matches; `APPROVED..` does NOT (the regex allows zero or one `.`).
- **No other content** — `APPROVED but change X`, `Yes, APPROVED`, `APPROVED!`, `APPROVED ✓` all FAIL the match. Any non-whitespace beyond the optional period rejects.

### Why exclude embedded qualifications

`APPROVED but change X` is genuinely ambiguous: the human approved the artifact AND requested a change. The orchestrator cannot infer which side wins. The safe behaviour is to treat the reply as NOT an unconditional approval and route the qualifier through the appropriate ad-hoc / change request handler (see *Ad-Hoc Request Handling* below). The human can always re-reply with bare `APPROVED` once the qualifier is split off.

### Numbered-option gates

`approve-impl.md` Step 2 and `create-pr.md` Step 3 present numbered choices (`[1] APPROVED`, `[2] CHANGES`, …). Those gates accept BOTH the numeric token (`1`) AND the literal word matched by the rule above (`APPROVED`, `Approved`, etc.). The numeric form is the primary contract for numbered gates; the literal-word form is a courtesy alias. A reply that names a non-existent option (`[3]` when only `[1]` and `[2]` exist) is rejected — re-render the prompt.

### Where this rule applies

| Site | Rule |
|---|---|
| `plan.md` GATE #1 ("Proceed only on receiving `APPROVED`") | Apply the canonical matcher. |
| `approve-impl.md` GATE #2 (numbered options) | Numeric primary; `APPROVED` literal accepted as alias. |
| `create-pr.md` GATE #3 (numbered options) | Numeric primary; `APPROVED` literal accepted as alias. |
| `review-response.md` (numbered options) | Numeric primary; no `APPROVED` literal accepted (the gate is YES/NO, not APPROVED/CHANGES). |
| Reviewer-Verdict field (`APPROVED` / `APPROVED_WITH_CONCERNS` / `CHANGES_REQUESTED`) | NOT covered — this is an agent-status enum (see `agents/shared/status-schema.md`), not a human gate. |

### Failure handling

If the reply does not match, do NOT infer intent. Re-render the gate prompt with a one-line preamble:

```
⚠️ Could not parse: "<verbatim reply>". Expected `APPROVED` (case-insensitive) or a numbered option. Please reply again.
```

Loop on invalid input has no explicit bound — the human can always pick a different option or explicitly type a `REQUEST <description>` to route through ad-hoc handling.

## Stalled-Agent Recovery

<!-- Added: follow-up to a tester-side bug where the agent ended without committing or emitting
     AGENT STATUS, and the orchestrator reasoned its way into committing on the agent's behalf —
     a CC-02.1 role-boundary violation.
     CC conventions applied: CC-02.1 (role boundary), CC-02.4 (status block), CC-02.5 (failure propagation). -->

An agent has **stalled** when ANY of the following is true after its SubagentStop fires:

- The response text is missing the `📋 AGENT STATUS` block entirely.
- The block is present but `Outcome` is `PARTIAL` / `FAILED` / `BLOCKED`.
- The block is present with `Outcome: SUCCESS` but the agent's expected commits did not land (e.g. tracker shows `Files changed:` but `git log` shows no new commit on the worktree branch).

When stall is detected, the orchestrator's recovery sequence is **non-negotiable**:

1. **Do NOT commit on the agent's behalf.** Tests are tester-owned. Production code is developer-owned. Plan / tracker files are planner-owned. Even when a commit "looks safe", an orchestrator-authored commit corrupts the audit trail (commit author / co-author lines, the `[WIP]` prefix convention, the `Self-review:` chain). Per rule #1's last bullet, this is forbidden.
2. **Inspect the worktree state.** If the agent left uncommitted files in the worktree, capture the file list — it goes into the re-invocation prompt verbatim.
3. **Re-invoke the same agent** with an explicit continuation prompt:
   ```
   Your previous run stopped without completing the AGENT STATUS contract. Uncommitted
   files in your worktree at <path>:
     - <file 1>
     - <file 2>
   1. Review the existing files for correctness (do NOT start from scratch).
   2. Commit them with the standard subject format (or a `[WIP]` prefix if still partial).
   3. Emit `📋 AGENT STATUS` per agents/shared/status-schema.md.
   You are mid-task — your goal is graceful termination of the previous run, not a fresh start.
   ```
4. **If the re-invocation also stalls** (rare — typically indicates a structural problem with the task), route to R-phase recovery (`/dev-workflow resume <id>`) per `commands/resume.md`. R will surface the stall to the human; the human chooses to escalate, split the task, or abort.
5. **Never silently retry more than once.** Two stalled invocations = R-phase. Three stalled invocations = mandatory escalation.

The same recovery applies whether the stall was caused by a turn-cap hit, an API error, a tool failure, or an agent refusal. The orchestrator's role is to **route** the recovery, never to **perform** it.

## Agent Response Contract

All agents end every response with a `📋 AGENT STATUS` block. The orchestrator MUST parse this block after every agent invocation to determine the next action.

**Decision matrix based on Outcome:**

| Outcome | Orchestrator action |
|---------|-------------------|
| `SUCCESS` | Proceed to next step in workflow |
| `DONE_WITH_CONCERNS` | Proceed to next step (same as SUCCESS), but relay the Developer's `Concerns` field to the Reviewer as additional context for extra scrutiny. |
| `PARTIAL` | Read Blockers field. Retry the failed portion with targeted instructions. |
| `FAILED` | Read Blockers and build/test output. If retryable, re-invoke agent (max 1 retry). If not, pause workflow and report to human. |
| `BLOCKED` | Read Blockers field. If human input needed, present to human. If dependency-related, resolve dependency first. |

**Phase 6 Reviewer Verdict matrix** (separate field from `Outcome`; only applies when `Outcome: SUCCESS`):

| Verdict | Orchestrator action |
|---------|---------------------|
| `APPROVED` | Present the full Pre-PR Report to the human and request the gate-3 approval as normal. |
| `APPROVED_WITH_CONCERNS` | Treat the same as `APPROVED` for control-flow purposes — present the report, surface the `Warnings`/`Suggestions` sections prominently in the gate prompt, and request the gate-3 approval. The human may proceed or ask for fixes. |
| `CHANGES_REQUESTED` | Do NOT present a normal approval gate. Show the `Critical issues` block and offer the fix-or-override choice defined in `commands/create-pr.md` Step 3. |

If the Phase 6 reviewer reports `Outcome: FAILED` (build/test broken, worktree missing, etc.) the standard `Outcome` matrix above takes precedence and the Verdict is ignored.

**Per-agent status fields:**

| Agent | Key status fields |
|-------|------------------|
| **Planner** | `Outcome`, `Files written`, `Files failed`, `Blockers` |
| **Developer** | `Repo`, `Repo path`, `Worktree`, `Worktree branch`, `Commit`, `Build result`, `Build attempts`, `Files changed`, `Self-review` (no tracker fields — orchestrator owns tracker) |
| **Reviewer (Phase 3/5)** | `Repo`, `Repo path`, `Spec compliance`, `Code quality verdict`, `Verdict`, `Worktree reviewed`, `Build verified`, `Tests verified`, `Review comments` (full `[S<n>]`/`[R<n>]`/`[T<n>]` list) |
| **Tester** | `Repo`, `Repo path`, `Task`, `Tests written`, `Tests passing`, `Coverage %`, `Test attempts`, `Commit` |
| **Reviewer (Phase 6)** | `Verdict`, `AC coverage`, `Task coverage`, `Test coverage`, `Critical issues` — full Pre-PR Report in response body. See `agents/reviewer/pre-pr.md`. |
| **Reviewer (Phase 7)** | `Outcome`, `Comments analysed`, `Valid`, `Invalid`, `Partial` — full PR Comment Analysis Report in response body. See `agents/reviewer/pr-comment-analysis.md`. |

**Parsing rules:**
1. Look for `📋 AGENT STATUS` in the agent response.
2. If the block is MISSING, the Stop hook will catch this and force the agent to add it. If after retry it's still missing, log a warning and proceed based on the agent's prose output.
3. Extract the `Outcome` field first — it determines the branch.
4. For Developer: also check `Repo`, `Repo path`, `Worktree`, `Worktree branch`, `Commit`, `Build result`, `Build attempts`, and `Self-review`. If `Build attempts: 3` and `FAILED`, do NOT retry — escalate. The `Repo`, `Repo path`, and worktree fields are REQUIRED for the reviewer and merge steps. Use `Repo` to map the agent back to its lane.

   **Self-review enforcement:** the combination `Outcome: SUCCESS` + `Self-review: FAIL` is invalid by definition (self-review is a commit precondition). If you observe it, override the Outcome to `PARTIAL` and re-route via the standard `PARTIAL` handler — re-invoke the Developer with the failed self-review check(s) as focused instructions. Do not advance the lane to review while self-review is failing.
5. For Reviewer: check `Verdict`. If `CHANGES_REQUESTED`, extract structured comments from the `Review comments` field and route them per the three-prefix model in *Structured Review Comments* below — `[R<n>]` to the Developer, `[T<n>]` to the Tester, `[S<n>]` by file path (production → Developer, test → Tester). The orchestrator (not the reviewer) updates the task tracker.
6. For Tester: check `Tests passing` and `Coverage`. If `Coverage` < 90% after `Test attempts: 3`, escalate.

## Structured Review Comments

> Authoritative reference: [comment-routing](comment-routing.md) (canonical prefix grammar, file-path routing, ambiguous-`[S<n>]` default-to-Developer rule, two-phase processing, and Phase 5 `[R<n>] → escalate`).

The Reviewer uses three comment prefixes (emission format in `agents/reviewer/index.md`):
- `[S<n>]` — spec compliance failure (Phase A). Short-circuits Phase B. Routed by file path: production-code path → Developer; test-file path → Tester. **Ambiguous cases (path mentions both) default to the Developer** per `comment-routing.md`.
- `[R<n>]` — code quality issue in **production** code (Phase B), with severities `CRITICAL | WARNING | SUGGESTION`. Routed to the Developer.
- `[T<n>]` — code quality / Test-Outline issue in **test** code (Phase B), with the same severities. Routed to the Tester.

The orchestrator relays the full `Review comments` field verbatim to each downstream agent — it does not parse individual comments beyond grouping by prefix to choose the recipient. If spec fails (Phase A), only `[S<n>]` comments exist; code quality is skipped. There is no separate "suggestion" prefix — `SUGGESTION` is a severity inside `[R<n>]`/`[T<n>]`.

When both `[R<n>]` and `[T<n>]` are emitted in the same review round, invoke the Tester first (so tests stabilise) and then the Developer in the same worktree. Routing details live in `commands/develop.md` Step 4.

## Error Handling

### Subagent File Operation Errors

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

### File Operation Error Markers

Scan for these error markers in agent responses (especially from the Planner):

```
⚠️ FILE OPERATION FAILED
- Operation: Write | Edit
- Target path: <path>
- Error: <error message>
- Action taken: <what the agent tried>
```

**If found:** correct the path and re-invoke, or pause and report to human.

### General Error Recovery

- If a session ends mid-workflow, the task tracker preserves state.
- The next session reads the tracker and resumes from the correct point.
- The `inject-tracker-state` hook automatically loads tracker state when agents start.

### API Failure Recovery

If an agent turn ends unexpectedly (API error, timeout), the `StopFailure` hook automatically:
1. Captures the current tracker state
2. Detects in-progress tasks and uncommitted changes
3. Injects resume instructions into the next turn

The orchestrator should read the recovery context and resume from the exact point of failure.

### Worktree Reconciliation on Resume

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

## Ad-Hoc Request Handling

Between approval gates the human may submit ad-hoc requests — typically while exercising the implementation before Phase 4 approval, at GATE #2 / GATE #3 instead of `APPROVED`, or mid-phase via `/dev-workflow request <story-id> "<text>"`. The orchestrator MUST route every such request through `commands/handle-request.md` before any code work begins; silently treating a request as a free-form "fix this" instruction is a workflow failure.

### Mandatory Triage Before Action

1. **No code work without triage.** When a request arrives, the orchestrator does NOT invoke the Developer, the Tester, or the Planner directly. The first agent invocation MUST be `@ai-sdlc-reviewer` with `mode: request-triage` to classify the request against the approved plan and acceptance criteria.
2. **In-scope items still require human confirmation (GATE #5).** Even when the Reviewer classifies a request as `IN_SCOPE_BUG` or `IN_SCOPE_AC_MISS`, the orchestrator MUST present the triage report and wait for the human's confirmation before invoking the Planner with `MODE: ad-hoc-tasks`. Auto-creating tasks bypasses the gate and violates rule #2.
3. **Out-of-scope items are never silently merged.** When the Reviewer returns `OUT_OF_SCOPE` or `PLAN_CONFLICT`, the orchestrator MUST surface the classification with the conflicting plan section (for `PLAN_CONFLICT`) and the explicit `[a] Expand scope / [b] Defer as new story / [c] Withdraw` options. The orchestrator does NOT decide which option to take.
4. **Plan amendments re-enter GATE #1 scoped to the amendment delta.** When the human picks `[a] Expand scope`, the Planner runs in `MODE: plan-amendment`, the orchestrator re-presents the amendment for approval (a scoped re-run of GATE #1 limited to the amendment section), and only on approval invokes `MODE: ad-hoc-tasks` to create the tracker rows. A rejected amendment reverts the plan write and falls through to `[b]` or `[c]`.

### Mid-Phase Request Handling (Synchronous, Non-Negotiable)

When a request arrives mid-Phase 3 or mid-Phase 5 (background agents in flight), the orchestrator handles it **synchronously and in-line** — there is no orchestrator-side queue and no "drain at the next safe checkpoint" hook. Specifically:

1. The orchestrator captures the request text and assigns the next `[AHR-<n>]` ID **immediately**.
2. The orchestrator runs `commands/handle-request.md` Steps 2–6 in the current turn — Reviewer triage, GATE #5 presentation, and (on confirmation) Planner row-append. Steps 2–6 only touch the tracker via the Planner and do not require any lane to be idle.
3. **Concurrency model:** background agents spawned with `run_in_background: true` are independent processes — they continue executing while the orchestrator handles the request. But the orchestrator is a single turn-based loop and cannot *service* their completion notifications until it finishes the current request-handling turn (which includes a human gate at Step 4 — potentially a long pause). Notifications that arrive during request handling queue up at the loop layer; they are processed in the usual `develop.md` Step 2 order **after** Step 6 returns. Background agents are not preempted, killed, or paused — they simply complete on their own clock and their completion handlers are deferred.
4. After Step 6, control returns to the standard lane main loop. New ad-hoc rows are ⏳ Pending in the tracker; the lane picks them up in tracker order on its next idle-cycle (after any deferred completion handlers run and the currently-running task completes), per the picker in `develop.md` Step 1. Since ad-hoc rows are appended **below** any existing pending main-table rows in the same repo, they are scheduled *after* those pending rows — not in front of them.
5. Phase 5 (`test.md`) interacts the same way: if a T-TEST task is in flight when a mid-phase request arrives, T-TEST continues to completion; ad-hoc rows are then picked up by their target repo's lane in the standard order. There is no explicit "pause Phase 5 to run ad-hoc" path — that's the gate-entry path's job.

**Practical impact**: a lane whose reviewer completes during request handling won't see its squash-merge until after GATE #5 closes. That latency is inherent to the single-loop orchestrator and is acceptable for the typical request-handling time. The orchestrator's documentation deliberately does NOT claim parallel orchestrator execution; only the background agents themselves run in parallel.

**Priority knob for the human**: if the in-scope ad-hoc item must run *before* additional main-table work proceeds, raise the request at the next gate (GATE #2 or GATE #3) instead of mid-phase. Gate-entry routes pause the workflow until the new batch is ✅ Done, then return to the gate; mid-phase routes do not.

### Tracker Section Ownership

The `## Ad-hoc Tasks (Batch <N>)` section is owned by the Planner (`MODE: ad-hoc-tasks`) — only the Planner creates row entries, only the orchestrator updates Status / Reviewer Verdict / Commit(s) on existing rows per the standard transitions. The same separation as the main task table applies.

The `## Deferred Requests` section is owned by the **orchestrator** (not the Planner). The orchestrator writes rows directly via Read+Write when the human picks `[2] Skip`, `[b] Defer as new story`, `[c] Withdraw`, `[d] Acknowledge`, `[g] Skip`, or `[SKIP-ALL]` at GATE #5. These are non-task records — there is no failure mode the Planner could add by being involved, and routing through the Planner would introduce an extra agent invocation for what is effectively a tracker append.

### Failure-Mode Pinning

These triage failure modes have prescribed handlers — the orchestrator MUST follow them and MUST NOT improvise alternatives:

1. **`Verdict: PLAN_NOT_FOUND`** (from any per-repo Reviewer in `mode: request-triage`) — escalate to the human and pause the request-handling flow. Do NOT fabricate a plan path. Do NOT retry with a guessed path. Do NOT proceed to GATE #5 with the remaining repos' reports (partial-state gates produce ambiguous human choices). The fix is human-side: rerun `/init-workspace` if `repos-paths.md` is stale, restore the plan from version control, or kill the request. The same rule applies to `Verdict: PLAN_NOT_FOUND` from `mode: pr-comment-analysis` in Phase 7 — handled there by `commands/review-response.md` Step 4, and pinned here for the same reason.
2. **`Verdict: TRIAGE_PARTIAL`** (Reviewer could not classify every request) — surface the unclassified rows via the GATE #5 decision matrix as `Classification: UNCLASSIFIED` with the `[f] Re-triage with hint / [g] Skip / [h] Override → <class>` choice set. Do NOT silently skip them and do NOT auto-classify them as `OUT_OF_SCOPE`. The matrix shape is the only handler — `TRIAGE_PARTIAL` never falls through.
3. **Plan-amendment rejection at the scoped GATE #1 re-presentation** — restore the plan from the orchestrator's `PLAN_SNAPSHOT` cache via the Write tool. Do NOT ask the Planner to undo its own append. Do NOT leave the rejected amendment in the plan file. The snapshot is workspace-agnostic (works whether the workspace is a git repo or not) and is the only durable rollback artifact.

### Repo-Scope Inference Bounds

When a mid-phase request via `/dev-workflow request <id> "<text>"` does not name a target repo, the orchestrator infers repos in scope by **substring-matching** repo names from `repos-metadata.md` against the request text. This is the only inference allowed. The orchestrator MUST NOT:

- Attempt semantic mapping (e.g. parsing "the API" → repo `api-gateway`, "the frontend" → repo `web-ui`). Semantic mapping is an LLM judgement and belongs to the Reviewer's classification, not the orchestrator's scoping.
- Read source code or any project file to determine scope. Source reading is a Reviewer responsibility (rule #1).

**Match classification**:

| Substring match count | State | Orchestrator action |
|-----------------------|-------|---------------------|
| Exactly 1 repo matched | **Resolved** | Invoke Reviewer for the matched repo only. |
| 0 repos matched | **No match** | Default to all repos. Invoke Reviewer for every repo in the tracker's `## Repo Status` section (populated from `repos-metadata.md`; the two sets are identical by construction — see `tracker-schema.md`). Over-broad scoping is self-correcting — the Reviewer returns `OUT_OF_SCOPE` or `INVALID` for the irrelevant repos and the GATE #5 matrix lets the human dismiss them. |
| 2 or more repos matched | **Ambiguous match** | Pause before triage. Present a disambiguation prompt to the human (see below) and resolve to a specific repo subset before invoking any Reviewer. |

**Ambiguous-match disambiguation prompt** (only fires for 2+ substring matches):

```
## Ad-Hoc Request — Repo Disambiguation

Request: "<verbatim text>"
Substring-matched repos: <repo-1>, <repo-2>, ... (matched on token "<token>")

Which repo(s) does this request target?
  [1] <repo-1>
  [2] <repo-2>
  [3] All matched repos (run triage in all of them)
  [4] All workspace repos (treat as "no match" — every repo gets triage)
  [5] Cancel — withdraw the request

  ⚠️ If you pick [3] and any matched repo has no plan slice (e.g. a repo
     added after the original plan), the per-repo Reviewer returns
     `Verdict: PLAN_NOT_FOUND` and — per the Failure-Mode Pinning rule —
     the entire batch escalates without proceeding to GATE #5. To avoid
     this cascade, pick a narrower numeric subset (e.g. "1,2") that only
     includes repos with plan slices.

Reply with one or more numbers (e.g. "1" or "1,2") or [5].
```

**Invalid-input fallback**: if the human's reply does not parse as one of `[1]`–`[5]` or a comma-separated list of valid numbers (e.g. they type free-form text, an out-of-range number, an empty line, or `3,99`), the orchestrator MUST re-render the prompt with a one-line preamble:

```
⚠️ Could not parse: "<verbatim reply>". Expected [1], [2], [3], [4], [5], or a comma-separated list of repo numbers (e.g. "1,2"). Please reply again.
```

The orchestrator does NOT infer intent from free-form text. The disambiguation prompt is the only orchestrator-side prompt that loops on invalid input; everything else uses Claude Code's standard handler. The loop has no explicit bound — the human can always type `[5] Cancel` to terminate. Two consecutive un-parseable replies are not flagged as a special case; the human is presumed to be reading the prompt.

**Provenance**: the disambiguation is recorded in the request's audit trail (the `[AHR-<n>]` row's Notes column carries `disambiguated-from: <token>` when this path fires).

**Why not always prompt the human?** Because the 0-match and 1-match cases are unambiguous and the prompt would be pure overhead. Substring-matching is deterministic; the 2+ case is the only one where the orchestrator genuinely cannot pick without a tie-break, and that's where the cost is worth paying.

**Why does `[3]` cascade on PLAN_NOT_FOUND rather than scoping it out?** Per the Failure-Mode Pinning rule above, `Verdict: PLAN_NOT_FOUND` from any per-repo Reviewer is a setup error — the orchestrator cannot quietly drop the affected repo and proceed because the human's choice of `[3]` was explicit. If we silently scoped out the broken repo, the human would not know one of their chosen repos was excluded. Escalating is the only safe behaviour; the inline warning in the prompt is the prevention mechanism.

### Provenance Marker

Every ad-hoc task row's `Notes` column MUST contain the `ad-hoc: [AHR-<n>]` token. The Phase 3 re-entry filter, the batch counter, and the post-completion gate-resumption logic all rely on this token. Removing or renaming it breaks the loop.
