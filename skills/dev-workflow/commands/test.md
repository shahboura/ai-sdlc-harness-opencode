# Phase 5: Test Hardening

> Authoritative references: [timestamp](../context/timestamp.md), [comment-routing](../context/comment-routing.md), [agent-response](../context/agent-response.md), [worktree-lifecycle](../context/worktree-lifecycle.md)

<!-- Changed by: dev-workflow-plan.md [M-05] [IMPL-05-02..04]
     Reason: Add citations to timestamp / comment-routing / agent-response per CC-04.3; add Review Rounds > 5 escalation bound per CC-05.1 / GAP-16.
     CC conventions applied: CC-04.3, CC-05.1, CC-07.3. -->

**Phase**: 5
**Actors**: Tester agent (auto-harden mode), then Reviewer agent (orchestrator coordinates)

## Purpose

By the time Phase 5 starts, every `test-required: true` task already has unit tests committed
(written by the Tester in Phase 3's TDD loop). Phase 5 is NOT primary test authoring.

The Tester's job here is:
1. **Gap-fill** — write integration and end-to-end tests that the per-task unit tests missed
   (cross-repo contract validation, edge cases requiring multiple components, etc.)
2. **Coverage enforcement** — run coverage analysis and add tests until ≥ 90% line coverage
   is reached on **all newly introduced/modified code in this story**. Coverage scope is the
   union of every changed file regardless of which task introduced it — including code from
   `test-required: false` tasks. Do NOT go out of scope to cover pre-existing code.
3. **No duplication** — do NOT rewrite unit tests that already exist from Phase 3
4. **No padding** — if a `test-required: false` task contains branching logic that can only
   reach 90% via meaningful tests, that is a Planner mis-classification, not a Tester problem.
   Add the minimum meaningful tests required (mirroring Phase 3 unit-style conventions), and
   flag the mis-classification in your AGENT STATUS `Blockers`/`Next action` field so the
   human can see it. Never invent tests purely to inflate coverage — the reviewer rejects
   coverage-padding tests.

## Prerequisites

- Human approved the implementation (Phase 4 complete).
- ALL development tasks are ✅ Done in the tracker.
- `Human approval (impl)` metric is set.
- If in direct phase mode, verify by reading the tracker:
  - All T(n) tasks must have status ✅ Done.
  - `Human approval (impl)` must not be `—`.

## Pre-Flight

Read the tracker and repo configuration:
```bash
cat .claude/context/repos-paths.md
cat .claude/context/language-config.md
```

## Steps

### Record Metric

Set `Test hardening started` to the canonical UTC timestamp (see [timestamp](../context/timestamp.md)).

### Per-Repo Test Hardening

For each affected repo (one per repo in the Repo Status section):

1. Resolve the repo's local path from the Repo Status section or `repos-paths.md`.
2. **Update tracker**: set `T-TEST-<RepoName>` → 🔧 In Progress and set task `Started` in Task Metrics.

#### Step 1: Harden Tests

Launch **@ai-sdlc-tester** with `mode: "auto-harden"` (can use `run_in_background: true` for parallel
per-repo hardening). Pass the repo path:

```
@ai-sdlc-tester Harden tests for Story $ARGUMENTS in repo <RepoName> (auto-harden mode).
Unit tests from Phase 3 already exist in the codebase at <REPO_PATH>.
Your job: gap-fill integration/E2E tests and enforce >=90% line coverage on new/modified code only. Do NOT go out of scope to cover pre-existing code. **Note**: the `/coverage-report` skill reports whole-file/package coverage — there is no diff-aware filter. Compute the new/modified scope yourself: `git -C <REPO_PATH> diff --name-only <feature-branch>...<default-branch>` lists the files to focus on, then read the parser output filtered to those files. See `coverage-report/SKILL.md` → *Scope — important*.

Do NOT rewrite or duplicate unit tests already written in Phase 3.
Do NOT write production code.
Commit test code only — do NOT update the task tracker.

[Include LANGUAGE_CTX — tester role: include test-cmd, coverage-cmd, coverage output, test framework; omit format-cmd]
[Include REPO_CTX]
(Templates: ../context/prompt-templates.md)

Instructions:
1. Read the plan at `ai/*-<story-id>/plan.md` (new canonical layout per [workflow-paths](../context/workflow-paths.md)) or `ai/plans/*<story-id>*.md` (legacy fallback) to understand the story's acceptance criteria. Note which
   tasks were marked `test-required: false` — their production code is in scope for the
   coverage gate even though Phase 3 wrote no tests for them.
2. Run the test command — confirm existing Phase 3 tests are passing.
3. Run the coverage command — identify coverage gaps across **all** new/modified code in
   this story (including `test-required: false` task code). Do NOT go out of scope to cover
   pre-existing code.
4. Write integration/E2E tests to close meaningful gaps in new/modified code.
   Assert the full observable contract in every test — not just HTTP status codes:
   - Success responses: assert every response body field defined in the plan's API contract.
   - Error responses (4xx, 5xx): assert the status code AND every field in the error envelope
     (e.g. `error`, `message`) as specified in the plan. Status-code-only assertions are incomplete.
   - If you reach a `test-required: false` code path that needs tests to clear the 90% gate,
     add the minimum meaningful tests AND flag the mis-classification in your AGENT STATUS
     (`Blockers` line: `test-required: false on T<n> needed tests for coverage`). Do NOT
     pad with assertion-free tests.
5. Re-run until all tests pass and coverage is >=90% on new/modified code.
6. Commit with co-author trailer:
   ```
   #<STORY-ID> test-harden: <slug>

   Co-Authored-By: Claude Code <noreply@anthropic.com>
   ```
```

After tester returns SUCCESS: **update tracker** — set `T-TEST-<RepoName>` → 🔄 In Review and record the tester's commit hash in `Commit(s)`.

#### Step 2: Review Tests

After tester completes, launch **@ai-sdlc-reviewer** with `mode: "auto"`:

```
@ai-sdlc-reviewer Review the test hardening for Story $ARGUMENTS in repo <RepoName>.
Unit tests from Phase 3 are already present. Review only the NEWLY ADDED integration/E2E tests.
Run the test command at <REPO_PATH> to verify all tests (Phase 3 + new) pass.
Run the coverage command to verify >=90% line coverage on new/modified code only.
Produce a structured verdict.
Do NOT update the tracker — return your review report to the orchestrator.

[Include LANGUAGE_CTX — reviewer role: include test-cmd, coverage-cmd; omit format-cmd]
[Include REPO_CTX]
(Templates: ../context/prompt-templates.md)
```

#### Handle Verdict

- If `Verdict: APPROVED` — **Update tracker**: set `T-TEST-<RepoName>` → ✅ Done, set `Reviewer Verdict` to ✅ Approved, and set task `Completed` in Task Metrics. Then proceed to next repo (or Phase 6 if all repos done).

- If `Verdict: CHANGES_REQUESTED` — **Update tracker**: set `T-TEST-<RepoName>` → 🔧 In Progress. Phase 5 only writes test code, so every structured comment from this review should be a `[T<n>]` (test code quality) or `[S<n>]` against a test file (test missing from the Test Outline). Relay both to the Tester. If the Reviewer emits any `[R<n>]` comment in Phase 5, **that is a Reviewer-side error** — Phase 5 has no developer to route it to and no production-code changes are in scope. The orchestrator's response is two complementary actions in lock-step: (i) **escalate** the `[R<n>]` to the human verbatim (the "route" per [comment-routing](../context/comment-routing.md) → P5 row), AND (ii) **pause** the affected lane's tracker state per the case below until the human resolves. The two actions are not alternatives. Handle the mixed-comment case in this order:

  1. **If the review contains both `[R<n>]` AND `[T<n>]/[S<n>]`**: relay the `[T<n>]/[S<n>]` set to the Tester per the standard handling — the lane keeps advancing on the legitimate findings. Separately, surface the `[R<n>]` to the human (see step 3 below).
  2. **If the review contains ONLY `[R<n>]`** (no test-code findings): the Tester has nothing to do. Pause the lane: leave `T-TEST-<RepoName>` in **🔄 In Review** (do NOT transition to 🔧 In Progress — the universal-rule write would re-stamp `Started` and lose audit fidelity for a "lane stuck on bad reviewer output" state). Wait for human direction.
  3. **In both cases, surface the prefix mismatch to the human verbatim** with the full `[R<n>]` comment body. The human decides whether the underlying issue is a real pre-existing bug worth a new story / ad-hoc request, a real find requiring an `[a] Expand scope` plan amendment, or noise that can be dismissed. Do NOT silently relay `[R<n>]` to the Tester — the test-only scope would force the Tester to either ignore it or step out of scope, both wrong.

  After the Tester returns SUCCESS (case 1) or the human resolves the stray `[R<n>]` (case 2), update T-TEST back to 🔄 In Review (case 1) or transition normally per the human's resolution (case 2). Loop back to Step 2.

#### Review-Round Escalation Bound (CC-09 — IMPL-05-03 / GAP-16)

<!-- Changed by: dev-workflow-plan.md [M-05] [IMPL-05-03]
     Reason: Document the Review Rounds > 5 escalation bound per CC-05.1 + CC-09; resolves GAP-16. -->

When `Review Rounds` on the lane's T-TEST exceeds **5** (the CC-09 default `max_review_rounds`; see [tracker-field-schema](../../../agents/shared/tracker-field-schema.md)), the orchestrator MUST stop the harden→review loop and escalate to the human. Five rounds is the elbow where productive review converges; rounds 6+ historically indicate plan / requirements drift, not code drift — escalating then is cheaper than another loop.

Routing of escalation comments follows [comment-routing](../context/comment-routing.md): in P5 test-harden context, `[R]` means production refactor required, which the Tester cannot perform (CC-02.1 boundary) — the orchestrator escalates to the human or triggers a P3 re-entry per `phase-re-entry.md`.

The bound is overridable per-story via the tracker's `Max Review Rounds:` field (CC-09 override path).

### Parallel Hardening (Multi-Repo)

When multiple repos exist, the orchestrator MAY launch testers in parallel across repos
(same pattern as Phase 3's parallel lanes). Each repo's tester runs independently.

### Record Final Metric

Once all repos are hardened and approved, set `Test hardening completed` to the canonical UTC timestamp (see [timestamp](../context/timestamp.md)).

## Next Phase

Proceed to **Phase 5.5: Static Security Review** — read and execute `commands/security-review.md`. The orchestrator auto-invokes P5.5 in full-pipeline mode; only after `Security review completed <ts>` is stamped (and GATE #2.5 cleared if it fired) does the workflow advance to **Phase 6: Create PR** (`commands/create-pr.md`).
