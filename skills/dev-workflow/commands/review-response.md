# Phase 7: PR Review Response

> Authoritative references: [provider-resolver](../context/provider-resolver.md), [summary-render](../context/summary-render.md), [phase-re-entry](../context/phase-re-entry.md), [timestamp](../context/timestamp.md), [comment-routing](../context/comment-routing.md), [agent-response](../context/agent-response.md), [workflow-paths](../context/workflow-paths.md)

> **Path resolution (M-14 IMPL-14-02)**: every inline reference to `ai/plans/<id>.md` / `ai/tasks/<id>.md` in this command is the **legacy** layout. Resolve actual paths via `ai/*-<work-item-id>/{plan,tracker,pr-comment-analysis-report-<n>}.md` (new canonical layout per [workflow-paths](../context/workflow-paths.md)); fall back to the legacy paths during the migration window.

<!-- Changed by: dev-workflow-plan.md [M-06] [IMPL-06-02, IMPL-06-04]
     Reason: Cite shared snippets + add canonical-spec header per CC-04.3 / CC-07.3 / CC-08.2.
     The Step 8b re-entry sequence (P3 re-entry + P5 re-trigger) is the GAP-07 duplicate
     that now defers to `phase-re-entry.md` rather than inlining the same prose as handle-request.md.
     CC conventions applied: CC-04.3, CC-07.3, CC-08.2. -->

**Phase**: 7
**Actor**: Orchestrator, Reviewer (analysis), Planner (task creation), Human gate (GATE #4)

## Prerequisites

- PR(s) created (Phase 6 complete).
- `PR created` timestamp is set in tracker.
- If in direct phase mode, verify both the tracker and plan exist (canonical M-14 layout first; legacy fallback during the migration window):
  ```bash
  # Canonical (M-14 per workflow-paths.md):
  ls ai/*-${STORY_ID}/tracker.md ai/*-${STORY_ID}/plan.md 2>/dev/null
  # Legacy fallback (deprecated):
  ls ai/tasks/*${STORY_ID}*.md ai/plans/*${STORY_ID}*.md 2>/dev/null
  ```

## Overview

This phase ingests unresolved review comments from open PR(s), challenges each comment
against the approved plan and acceptance criteria, and produces a findings report for the
human. If accepted, the Planner adds new tasks to the existing tracker and the workflow
re-enters the Phase 3 TDD development loop for those tasks only.

## Steps

### Step 1 — Read Configuration and Tracker

```bash
cat .claude/context/repos-paths.md
cat .claude/context/provider-config.md
cat .claude/context/language-config.md
```

Locate the tracker — canonical layout first, legacy fallback:

```bash
TRACKER=$(ls -t ai/*-${STORY_ID}/tracker.md 2>/dev/null | head -1)
[ -z "$TRACKER" ] && TRACKER=$(ls -t ai/tasks/*${STORY_ID}*.md 2>/dev/null | head -1)
PLAN=$(ls -t ai/*-${STORY_ID}/plan.md 2>/dev/null | head -1)
[ -z "$PLAN" ] && PLAN=$(ls -t ai/plans/*${STORY_ID}*.md 2>/dev/null | head -1)
```

Read every tracker matching the Story ID under both layouts and parse the tracker's **Repo Status** section to build a map of:
`repo-name → { local-path, feature-branch, default-branch }`

### Step 2 — Fetch PR Comments (per repo)

For each affected repo, determine the git provider from `provider-config.md` and read the
corresponding **PR review comments adapter** at
`skills/providers/<git-provider>/pr-comments.md`. This is distinct from
`pull-requests.md` (which covers PR creation) — the comments adapter declares the
`pr.find_for_branch`, `pr.list_review_comments`, and `pr.reply_to_review_comment`
capabilities used in this phase.

If `pr-comments.md` does not exist for the configured provider, surface this to the
human and end the phase — Phase 7 cannot proceed without the primitives. (See
`skills/providers/shared/capabilities.md` for the canonical capability list and which
providers declare support.)

Use the adapter to:
1. Look up the open PR/MR for the repo's feature branch (`pr.find_for_branch`).
2. Fetch all review threads / comment threads (`pr.list_review_comments`).
3. Filter to **unresolved threads only** — skip automated bot comments, CI check summaries,
   and already-resolved threads. The adapter declares its own bot-filter starter list;
   apply it client-side.

Collect for each unresolved comment:
- A sequential ID: `[PC-<n>]` (globally numbered across all repos, starting at 1)
- Repo name
- File path and line number (or `"general"` if not inline)
- Comment author and body text
- Thread ID (provider-native identifier used to post replies — persisted into the tracker in Step 7; do NOT rely on in-memory state)

**If no unresolved comments are found across all repos:**

```
## Phase 7: PR Review Response

No unresolved review comments found on PR(s) for Story #<STORY-ID>.

Options:
  [1] Re-check — comment threads may have been added recently
  [2] Skip — no action needed
```

Wait for the human's response. If [2], end the phase without updating metrics.

### Step 3 — Reviewer: Challenge Comments Against Plan and AC

For each repo that has unresolved comments, invoke `@ai-sdlc-reviewer` with
`mode: pr-comment-analysis` and `run_in_background: true`
(name: `reviewer-prcomment-<repo-name>`):

```
@ai-sdlc-reviewer Analyse PR review comments for Story $ARGUMENTS.

MODE: pr-comment-analysis

[Include LANGUAGE_CTX — reviewer role: include build-cmd, test-cmd; omit format-cmd]
(Templates: ../context/prompt-templates.md)

REVIEW CONTEXT:
- Repo: <repo-name>
- Repo path: <local repo path>
- Feature branch: <team-name>/feature/<id>-<slug>
- Default branch: <main | master>
- Plan path: <ai/plans/...>
- Story ID: #<STORY-ID>

PR COMMENTS TO ANALYSE:
[PC-<n>] Repo: <repo-name> | File: <file-path>:<line> (or "general") | Author: <author>
         <comment body text>

[PC-<m>] ...

Classify each comment and produce the PR Comment Analysis Report.
See agents/reviewer/index.md for the pr-comment-analysis mode instructions and report format.
```

**Launch all repo reviewers in a single message** (parallel via `run_in_background: true`).
Wait for all to complete.

### Step 4 — Merge Multi-Repo Reports

If multiple repos had comments, collect all PR Comment Analysis Reports. Present them
together, clearly separated by repo, with a merged summary count at the top:

```
Total across all repos — Valid: N | Invalid: N | Partial: N
```

**Verdict handling per repo report:**

Parse the `Verdict:` and `Unclassified:` lines from each sub-report's AGENT STATUS block.

- `Verdict: ANALYSIS_COMPLETE` — no special action; include the report as-is in the merged
  output.
- `Verdict: ANALYSIS_PARTIAL` — prepend an `## Unclassified Comments` block at the top of
  the merged output naming each repo with a non-zero `Unclassified:` count. The human at
  GATE #4 must decide whether to re-fetch, skip, or accept the partial classification.
- `Verdict: PLAN_NOT_FOUND` — this is `Outcome: FAILED`. Surface as a hard error per
  `orchestrator-rules.md` error handling. Do not proceed to Step 5 — escalate to the human.

### Step 5 — Present PR Comment Analysis Report to Human (GATE #4)

Display the full merged report.

```
## Phase 7: PR Review Response — Findings

<display report(s)>

The Reviewer has challenged each comment against the approved plan and acceptance criteria.

Options:
  [1] Accept all VALID/PARTIAL findings — create tasks and re-enter the dev loop
  [2] Accept selected findings — specify which [PC-<n>] numbers to address
  [3] Override a classification — specify which [PC-<n>] to reclassify and why
  [4] No action needed — skip

What would you like to do?
```

### Step 6 — Handle Human Response

**Option [1] — Accept all:**
Collect every `[PC-<n>]` classified `VALID` or `PARTIAL`. Proceed to Step 7.

**Option [2] — Accept selected:**
Parse the human's list (e.g., `"PC-1, PC-3"`). Proceed to Step 7 with only those comments.

**Option [3] — Override:**
Capture the human's reclassification reasoning. Re-invoke the relevant Reviewer(s) in
`pr-comment-analysis` mode (foreground, targeted to the specified comments) with the
human's reasoning appended as additional context. Re-present Step 5 with the updated report.

**Option [4] — No action:**
Record `PR review response: skipped` in the Workflow Metrics table. End this phase —
no tasks are created, no commits made.

### Step 7 — Planner: Add New Tasks to Existing Tracker

Collect the accepted `[PC-<n>]` comments along with the Reviewer's proposed task outlines.

Invoke `@ai-sdlc-planner` (foreground) with the existing tracker and plan. The Planner's
behaviour in this mode is documented in `skills/plan-generator/SKILL.md` under
**Phase 7 Amendment Mode** — the prompt below sets the orchestrator-side context
the skill needs (paths, story ID, accepted comments, round number); the skill
handles the row template, dependency-graph regeneration, and the no-reorder /
no-remove invariant on existing rows.

```
@ai-sdlc-planner Add new PR-response tasks to the existing tracker for Story $ARGUMENTS.

MODE: pr-response-tasks

CONTEXT:
- Tracker path: <ai/tasks/<existing-tracker-filename>>
- Plan path: <ai/plans/<existing-plan-filename>>
- Story ID: #<STORY-ID>
- Round: <N>   # 1 on the first Phase 7 invocation for this story, 2 on a second
               # round of PR comments, etc. Derived by the orchestrator from
               # the count of existing `## Amendments (PR Review Round …)`
               # headings in the tracker, plus one.

ACCEPTED PR COMMENTS TO ADDRESS:
[PC-<n>] Repo: <repo-name> | File: <file-path>:<line>
Reviewer classification: VALID | PARTIAL
Reviewer reasoning: <from analysis report>
Proposed task: <one-sentence description from Reviewer>

[PC-<m>] ...

Instructions:
1. Read the existing tracker and plan.
2. Identify the highest existing Task ID (e.g., if last task is T5, next is T6).
3. For EACH accepted PC comment, add ONE new task row to the tracker:
   - Task ID: T<next-n>
   - Repo: <repo-name from the PC comment>
   - Title: <concise title ≤ 60 chars derived from the proposed task>
   - Status: ⏳ Pending
   - Reviewer Verdict: —
   - Commit(s): —
   - Notes: PR-comment: [PC-<n>] thread_id=<provider-thread-id> | test-required: true
4. Add a Test Outline section for each new task to the PLAN document, following the same
   format and naming convention as the original Test Outline (Subject_Scenario_Outcome).
   Base the test names on the Reviewer's proposed task description.
5. **Regenerate the tracker's `## Dependency Graph` section** to include the new tasks.
   Follow the rendering rules in `plan-generator/SKILL.md` → *Dependency Graph rendering
   rules*. PR-response tasks typically have no `depends:` token (they originate from PR
   feedback, not the original DAG), so they appear as root nodes that flow into their
   repo's `T-TEST-<RepoName>` node via the implicit Phase 5 edge. If a PR-response task's
   Notes contains an explicit `depends:` token (rare — only when the human edits it during
   the Phase 7 gate), honour it.
6. Update the Workflow Metrics table: add `PR review response started | <timestamp>`.
7. Save the updated tracker and plan files. Verify each by reading them back.
```

Parse the Planner's `📋 AGENT STATUS`. If `Outcome: PARTIAL` or `FAILED`, follow the
error handling rules in `orchestrator-rules.md`.

After confirmed `Outcome: SUCCESS`, record `PR review response started` in orchestrator state.

### Step 8 — Re-Enter TDD Development Loop

Read and execute `commands/develop.md`, applying the following scope filter before starting:

> **Only process task rows that live under a `## Amendments (PR Review Round <N>)` heading AND have `Status: ⏳ Pending`.**

The filter is **section-based**, not content-based. Pre-C3 it matched on `Notes contains \`PR-comment:\``, which worked only because the `PR-comment:` token happened to be unique to Amendments rows by convention (per `tracker-schema.md` → *Notes column tokens*) — a future change that allowed the token in any other section would silently widen the filter. Section-based matching is the durable signal: the `## Amendments (PR Review Round <N>)` heading is the canonical owner of Phase 7 tasks, and the orchestrator already needs to know which round it's on to derive `Round: <N>` for the Planner invocation in Step 7.

All Phase 3 rules apply unchanged:
- TDD path for `test-required: true` tasks (Tester → Developer → Reviewer)
- Direct path for `test-required: false` tasks (Developer → Reviewer)
- Worktree isolation per task
- Sequential execution within each repo
- Parallel execution across repos (via `run_in_background: true`)
- Squash-merge on Reviewer approval

After all new tasks are ✅ Done across all repos, proceed to Step 8b.

### Step 8b — Re-trigger Phase 5 hardening on affected repos

Phase 7 amendments reuse the existing `T-TEST-<RepoName>` row (per
`plan-generator/SKILL.md` → *Phase 7 Amendment Mode*). The original Phase 5
hardening ran against the original code and is recorded as ✅ Done — but new
amendment production code has now landed on the feature branch and the 90%
coverage gate has never been checked against the union. Without this step,
amendments ship in the PR without coverage enforcement.

For each repo where this Phase 7 batch added at least one task, read the
`T-TEST-<RepoName>` row's Status:

- **`Status: ✅ Done`** → re-trigger Phase 5 hardening on this repo:
  1. Set `T-TEST-<RepoName>` → `🔧 In Progress` (legal `✅ Done → 🔧 In Progress`
     transition per `tracker-schema.md`; the `tracker-transition-guard` hook
     accepts it as a "rework" transition). Per the universal orchestrator rule
     "Set task `Started` (Task Metrics) when marking a task 🔧 In Progress"
     (`orchestrator-rules.md` → rule #3), this transition **also overwrites the
     original Phase 5 `Started` timestamp** on the T-TEST row. Both `Started`
     and `Completed` on the row reflect the most recent hardening pass; the
     audit trail of "when did the *first* Phase 5 run start" is lost from the
     T-TEST row but preserved via `Test hardening started` in the Workflow
     Metrics table (which is NOT overwritten — see the workflow-metrics
     non-update paragraph below).
  2. Invoke `commands/test.md` Step 1 (auto-harden Tester) and Step 2 (Reviewer)
     for this repo, following the exact same loop as the original Phase 5 run.
  3. On Reviewer `APPROVED` → set `T-TEST-<RepoName>` → `✅ Done`, set
     `Reviewer Verdict` to ✅ Approved, set `Completed` in Task Metrics to the
     current UTC timestamp (overwrites the original Phase 5 completion stamp
     for this T-TEST row — the row records the most recent hardening pass).
  4. On Reviewer `CHANGES_REQUESTED` → loop per the standard Phase 5 handling
     (relay all `[T<n>]`, `[S<n>]`, and any `[R<n>]` comments to the Tester;
     T-TEST stays `🔧 In Progress` until the Tester returns SUCCESS and the
     Reviewer approves on the next round).

- **`Status` is anything else** → the upcoming or in-flight Phase 5 will
  naturally cover the new amendment code when it runs. Do not re-trigger.
  This case is rare (it implies the workflow resumed mid-Phase-5 or the
  amendment landed before the original Phase 5 completed), but the guard
  prevents a redundant re-trigger and an illegal transition.

Multiple repos may be re-triggered in parallel via `run_in_background: true`
per the standard Phase 5 parallel-hardening pattern. Sequential within each
repo — at most one in-flight Tester or Reviewer per repo.

The Workflow Metrics `Test hardening started` / `Test hardening completed`
timestamps are NOT re-set by this step — they record Phase 5's first run, and
Phase 7's re-trigger is tracked by the per-row `Completed` Task Metric on
`T-TEST-<RepoName>` and the `PR review response completed` metric. Re-stamping
the Phase 5 metrics would fragment the audit trail across phases.

After every re-triggered `T-TEST-<RepoName>` returns to ✅ Done, proceed to Step 9.

### Step 9 — Record Completion and Offer PR Replies

Update the tracker Workflow Metrics: set `PR review response completed` to
`date -u +"%Y-%m-%d %H:%M UTC"`.

Create a **new tracker-update commit** on top of the Phase 7 task commits. **Do NOT amend.**
By this point, HEAD is the most recent Phase 7 task squash-merge — not the Phase 6 tracker
commit — so `git commit --amend` would silently rewrite a task commit's tree with tracker
content. A new commit also keeps the tracker's recorded squash-merge SHAs accurate (an
amend that autosquashes back into the Phase 6 tracker commit would rewrite the SHAs of
every Phase 7 task commit above it, making the values just recorded in the tracker stale).

First, determine whether the workspace is itself a git repository:

```bash
git -C ai/<YYYY-MM-DD>-<work-item-id>/ rev-parse --is-inside-work-tree 2>/dev/null
```

**If the workspace IS a git repo** (exits 0 — workspace == repo, single-repo case):

Stage both `ai/tasks/` and `ai/plans/`. The plan is included for the same reason as in the
workspace-not-a-git-repo branch below: a Phase 7 batch may have arrived via `[a] Expand scope`
and run `MODE: plan-amendment`, which appends a `## Plan Amendment — Ad-Hoc Round <N>`
section to the workspace plan file. Without staging the plan, the amendment stays
uncommitted on the feature branch — the tracker references plan content that the repo's
committed plan file does not contain. If the plan was unchanged this round, staging
`ai/<YYYY-MM-DD>-<work-item-id>/` includes the plan file as a no-op (Git skips byte-
identical files) and the commit lands with only the tracker delta.

```bash
git add ai/<YYYY-MM-DD>-<work-item-id>/
git commit -m "$(cat <<'EOF'
#<STORY-ID> #TPR-RESP: record PR review response completion

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git push origin <feature-branch>
```

**If the workspace is NOT a git repo** (tracker was copied into the repo in Phase 6 Step 6):

Sync the updated tracker **and the plan** back into each affected repo using the
**Read + Write** tools (not `cp` — the `bash-write-guard` hook blocks Bash writes
to `ai/` paths). The plan is included because a Phase 7 batch may have arrived via
the inter-gate ad-hoc flow's `[a] Expand scope` path, which invokes
`MODE: plan-amendment` and appends a `## Plan Amendment — Ad-Hoc Round <N>`
section to the workspace plan file. Without re-syncing the plan, the per-repo copy
committed in Phase 6 would stay frozen at the pre-amendment state and the next
holistic review (or any human looking at the merged PR) would see a tracker
referring to a plan section that doesn't exist in the repo:

- Read `ai/<YYYY-MM-DD>-<work-item-id>/tracker.md` (workspace) → Write to `<REPO_PATH>/ai/<YYYY-MM-DD>-<work-item-id>/tracker.md`
- Read `ai/<YYYY-MM-DD>-<work-item-id>/plan.md` (workspace)    → Write to `<REPO_PATH>/ai/<YYYY-MM-DD>-<work-item-id>/plan.md`

If the workspace plan file's mtime is unchanged since the last sync (Phase 6 Step 6
or a prior Phase 7 Step 9), the Write call is a no-op on content; skipping the read
is a valid optimisation but not required — the cost of an extra Read+Write is
trivial compared to the cost of a missed amendment, and the no-op write doesn't
dirty the working tree (Git's `add` ignores byte-identical files).

Then commit and push from the repo:

```bash
git -C "<REPO_PATH>" add ai/<YYYY-MM-DD>-<work-item-id>/
git -C "<REPO_PATH>" commit -m "$(cat <<'EOF'
#<STORY-ID> #TPR-RESP: record PR review response completion

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git -C "<REPO_PATH>" push origin <feature-branch>
```

Both pushes are fast-forward (a new commit on top of the remote's tip), so
`--force-with-lease` is not required. If the plan was unchanged this round, the
commit's tree has no plan delta and staging `ai/<YYYY-MM-DD>-<work-item-id>/`
includes the plan file as a no-op — the commit still lands cleanly because the
tracker delta is independent.

Present to the human:

```
## Phase 7: PR Review Response — Complete

All <N> PR-response task(s) have been implemented.

Would you like me to reply to the addressed PR comment threads with commit references?
  [YES] Post replies
  [NO]  Skip
```

**If YES:** Read the tracker's Notes column for every task whose Notes contain `PR-comment:`.
Extract the `thread_id=<value>` stored there by the Planner in Step 7. For each addressed
`[PC-<n>]` comment, use the PR comments adapter to post a reply on the original thread:

```
Addressed in commit <squash-merge-hash>: <one-sentence summary of what was changed>
```

Route through `skills/providers/<git-provider>/pr-comments.md` (the
`pr.reply_to_review_comment` capability). The thread IDs come from the tracker — not from
session memory — so this step is safe to run even after a session interruption.

### Step 10 — T2 Metrics Collection

Per the P9 metrics-collector contract (`skills/metrics-collector/SKILL.md`),
P7 triggers metrics aggregation at **T2** with `--round <n>` at the end of
each review cycle (1-indexed: first review round is `--round 1`, second is
`--round 2`, etc.). Use the same workflow directory the rest of P7
operates against.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/metrics_collector.py" \
    "ai/<YYYY-MM-DD>-<work-item-id>" \
    --round <n>
```

The round number for this invocation equals the count of distinct
`pr-comment-analysis-report-*.md` files in the workflow directory after the
current cycle's analysis was written. The aggregator computes
`p7_duration_minutes` from `PR created` → `PR review response completed`,
and `pr_review_rounds` from the file count itself.

Exit semantics match T1: `0` success, `1` validation failure with
`.error.md` sibling, `2` precondition unmet. On non-zero, surface
`.error.md` to the human but do not abort P7 — the response loop has
already completed; the metrics row is a non-blocking observation.

---

## Re-Entry

Phase 7 can be run multiple times for the same PR (e.g., a second round of reviewer
feedback). Each invocation discovers newly unresolved threads, creates a fresh batch of
`PR-comment:` tasks, and runs the dev loop for those tasks only. Prior PR-response tasks
remain Done and are not re-processed.

## Single-Repo Backward Compatibility

If only one repo is affected, this behaves identically — one Reviewer analysis, one human
gate, one Planner invocation, one sequential dev loop.
