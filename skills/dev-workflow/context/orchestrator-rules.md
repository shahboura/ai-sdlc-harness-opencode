# Orchestrator Rules

> Owner: cross-cutting
> Version: 2.0

<!-- Updated by: dev-workflow-plan.md [M-26] [IMPL-26-03]
     Reason: US-E03-004 surgery — moved per-phase detail to sibling context files to bring
     this file within the CC-04.8 context-file hard cap (≤ 200 lines).
     Sections moved: Error Handling → error-handling.md; Ad-Hoc protocol → ad-hoc-protocol.md;
     Stalled-Agent Recovery → recovery-protocol.md; Agent Response Contract → agent-response.md;
     Structured Review Comments → comment-routing.md.
     CC conventions applied: CC-04.8. -->

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
   - **Commit code on behalf of an agent that stopped without committing.** If a Developer or Tester ends without committing its own work (typical cause: hit `maxTurns` cap mid-iteration), the correct recovery is **re-invocation**, NOT orchestrator-side `git commit`. Even though the orchestrator is allowed git operations (rule #3), committing test or production code that an agent wrote crosses the CC-02.1 role boundary — the commit becomes orchestrator-authored on the audit trail, the agent's `📋 AGENT STATUS` contract is silently bypassed, and the workflow loses traceability. See [recovery-protocol.md](recovery-protocol.md) → *Stalled-Agent Recovery* for the correct sequence.

2. **ALWAYS delegate to the correct agent.** Every phase has a designated agent:
   - Phase 1 & 2: `@ai-sdlc-planner` (requirements analysis, plan generation, file creation)
   - Phase 3: `@ai-sdlc-developer` (implementation) and `@ai-sdlc-reviewer` (code review)
   - Phase 4: orchestrator only reads tracker and presents summary
   - Phase 5: `@ai-sdlc-tester` (test writing) and `@ai-sdlc-reviewer` (test review)
   - Phase 6: orchestrator presents summary, then uses `pr-creator` skill
   - Phase 7: `@ai-sdlc-reviewer` (pr-comment-analysis mode), `@ai-sdlc-planner` (pr-response-tasks mode), then re-enter Phase 3 loop for new tasks

   > **Agent invocation contract (CC-04).** The `@ai-sdlc-X` form above is mention syntax for delegation prose. When invoking the `Agent` tool, pass the fully-qualified `subagent_type`:
   >
   > | Mention | `subagent_type` |
   > |---|---|
   > | `@ai-sdlc-planner` | `ai-sdlc-harness:planner:ai-sdlc-planner` |
   > | `@ai-sdlc-developer` | `ai-sdlc-harness:developer:ai-sdlc-developer` |
   > | `@ai-sdlc-tester` | `ai-sdlc-harness:tester:ai-sdlc-tester` |
   > | `@ai-sdlc-reviewer` (Phase 3 per-task review / Phase 5 test review) | `ai-sdlc-harness:reviewer:ai-sdlc-reviewer` |
   > | `@ai-sdlc-reviewer` (Phase 6 pre-PR mode) | `ai-sdlc-harness:reviewer:ai-sdlc-pre-pr` |
   > | `@ai-sdlc-reviewer` (Phase 7 pr-comment-analysis mode) | `ai-sdlc-harness:reviewer:ai-sdlc-pr-comment-analysis` |
   > | `@ai-sdlc-reviewer` (inter-gate request-triage mode) | `ai-sdlc-harness:reviewer:ai-sdlc-request-triage` |

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

## Constraints

1. **Orchestrator does NOT do agent work.** Violation is a workflow failure.
2. **Four mandatory human gates plus an inter-gate ad-hoc gate (GATE #5)**: after planning (Phase 2), after development before tests (Phase 4), before PR creation (Phase 6), before creating PR-response tasks (Phase 7), and before creating ad-hoc tasks from inter-gate requests (GATE #5, on-demand, see [ad-hoc-protocol.md](ad-hoc-protocol.md)).
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

`APPROVED but change X` is genuinely ambiguous: the human approved the artifact AND requested a change. The orchestrator cannot infer which side wins. The safe behaviour is to treat the reply as NOT an unconditional approval and route the qualifier through the appropriate ad-hoc / change request handler (see [ad-hoc-protocol.md](ad-hoc-protocol.md)). The human can always re-reply with bare `APPROVED` once the qualifier is split off.

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

---

> **See also (detail sections moved in US-E03-004 surgery):**
> - [error-handling.md](error-handling.md) — Subagent file errors, worktree reconciliation, API failure recovery
> - [ad-hoc-protocol.md](ad-hoc-protocol.md) — Ad-hoc request triage, mid-phase handling, repo disambiguation
> - [recovery-protocol.md](recovery-protocol.md) — R-phase recovery, stalled-agent recovery sequence
> - [agent-response.md](agent-response.md) — Agent Response Contract, per-agent status fields, parsing rules
> - [comment-routing.md](comment-routing.md) — Structured review comment prefix grammar and routing
