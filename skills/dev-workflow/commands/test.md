# Phase 5: Test Hardening

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

Set `Test hardening started` to the output of `date -u +"%Y-%m-%d %H:%M UTC"`.

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
Your job: gap-fill integration/E2E tests and enforce >=90% line coverage on new/modified code only. Do NOT go out of scope to cover pre-existing code.

Do NOT rewrite or duplicate unit tests already written in Phase 3.
Do NOT write production code.
Commit test code only — do NOT update the task tracker.

[Include LANGUAGE_CTX — tester role: include test-cmd, coverage-cmd, coverage output, test framework; omit format-cmd]
[Include REPO_CTX]
(Templates: ../context/prompt-templates.md)

Instructions:
1. Read the plan at ai/plans/* to understand the story's acceptance criteria. Note which
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

- If `Verdict: CHANGES_REQUESTED` — **Update tracker**: set `T-TEST-<RepoName>` → 🔧 In Progress. Phase 5 only writes test code, so every structured comment is routed to the Tester regardless of prefix: relay all `[T<n>]`, `[S<n>]`, and any `[R<n>]` comments (the last is an out-of-band reviewer error worth surfacing — include them verbatim and flag the prefix mismatch to the human if they recur). The tester addresses and resubmits. After tester SUCCESS, update back to 🔄 In Review. Loop back to Step 2.

### Parallel Hardening (Multi-Repo)

When multiple repos exist, the orchestrator MAY launch testers in parallel across repos
(same pattern as Phase 3's parallel lanes). Each repo's tester runs independently.

### Record Final Metric

Once all repos are hardened and approved, set `Test hardening completed` to the output of
`date -u +"%Y-%m-%d %H:%M UTC"`.

## Next Phase

Proceed to **Phase 6: Create PR** — read and execute `commands/create-pr.md`.
