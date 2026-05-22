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

- PR(s) created (Phase 6 complete); `PR created` timestamp is set in tracker.
- Tracker and plan exist (prefer canonical `ai/*-${STORY_ID}/{tracker,plan}.md`; legacy fallback during migration).

## Overview

Ingests unresolved PR review comments, challenges each against the approved plan and AC, presents findings for human approval. Accepted comments become new tasks; workflow re-enters Phase 3 TDD loop for those tasks only.

## Steps

### Step 1 — Read Configuration and Tracker

```bash
cat .claude/context/repos-paths.md
cat .claude/context/provider-config.md
cat .claude/context/language-config.md
```

Locate tracker and plan (canonical `ai/*-${STORY_ID}/` first, legacy fallback). Parse **Repo Status** → `repo-name → { local-path, feature-branch, default-branch }`.

### Step 2 — Fetch PR Comments (per repo)

For each repo, read the provider's adapter at `skills/providers/<git-provider>/pr-comments.md` (`pr.find_for_branch`, `pr.list_review_comments`, `pr.reply_to_review_comment`). If the adapter is missing, surface to human and end the phase.

Use adapter to: (1) find the open PR for the feature branch; (2) fetch all review threads; (3) filter to **unresolved only** (skip bots, CI checks, resolved threads).

Collect per unresolved comment: sequential `[PC-<n>]` ID, repo name, file+line (or `"general"`), author, body text, thread ID (persisted to tracker in Step 7 — do NOT rely on in-memory state).

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

For each repo with unresolved comments, invoke `@ai-sdlc-reviewer` (`mode: pr-comment-analysis`, `run_in_background: true`, name: `reviewer-prcomment-<repo-name>`):

```
@ai-sdlc-reviewer Analyse PR review comments for Story $ARGUMENTS.
MODE: pr-comment-analysis
[Include LANGUAGE_CTX — build-cmd, test-cmd; omit format-cmd]
REVIEW CONTEXT: Repo, Repo path, Feature branch, Default branch, Plan path, Story ID
PR COMMENTS TO ANALYSE: [PC-<n>] Repo | File:line | Author | <body> ...
Classify each and produce the PR Comment Analysis Report (see agents/reviewer/index.md).
```

**Launch all repo reviewers in a single message.** Wait for all to complete.

### Step 4 — Merge Multi-Repo Reports

Collect all reports, separated by repo, with merged summary at the top:
`Total across all repos — Valid: N | Invalid: N | Partial: N`

Verdict routing: `ANALYSIS_COMPLETE` → include as-is. `ANALYSIS_PARTIAL` → prepend `## Unclassified Comments` block (human at GATE #4 decides). `PLAN_NOT_FOUND` → hard error; escalate, do not proceed to Step 5.

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

- **[1] Accept all:** Collect every `VALID`/`PARTIAL` `[PC-<n>]`. Proceed to Step 7.
- **[2] Accept selected:** Parse human's list; proceed to Step 7 with only those.
- **[3] Override:** Re-invoke Reviewer(s) with human's reasoning; re-present Step 5.
- **[4] No action:** Record `PR review response: skipped` in Workflow Metrics. End phase.

### Step 7 — Planner: Add New Tasks to Existing Tracker

Invoke `@ai-sdlc-planner` (foreground). Behaviour documented in `skills/plan-generator/SKILL.md` → **Phase 7 Amendment Mode**:

```
@ai-sdlc-planner Add new PR-response tasks to the existing tracker for Story $ARGUMENTS.
MODE: pr-response-tasks
CONTEXT:
- Tracker path: <workflow_dir>/tracker.md
- Plan path: <workflow_dir>/plan.md
- Test-outline path: <workflow_dir>/test-outline.md
- Story ID: $ARGUMENTS
- Round: <N>
  (Round = count of existing `## Amendments (PR Review Round …)` headings + 1)

ACCEPTED PR COMMENTS TO ADDRESS:
[PC-<n>] Repo | File:line | Classification | Reviewer reasoning | Proposed task
[PC-<m>] ...

Instructions:
1. Read tracker, plan, and test-outline. Find highest Task ID.
2. For EACH accepted PC comment, add one task row under `## Amendments (PR Review Round <N>)` in the tracker:
   Notes: PR-comment: [PC-<n>] thread_id=<id> | test-required: true
3. Append a `## Test Outline — PR Review Round <N>` section to **`test-outline.md`** (NOT plan.md), with one `## T<n>: …` block per new task (Subject_Scenario_Outcome convention). Keep the file in lock-step with the new tracker rows.
4. Regenerate `## Dependency Graph` (new tasks as root nodes → T-TEST-<RepoName>).
5. Add `PR review response started | <timestamp>` to Workflow Metrics.
6. Save and verify tracker and test-outline.
```

On `Outcome: PARTIAL`/`FAILED` follow `orchestrator-rules.md` error handling. On `SUCCESS`, record `PR review response started`.

### Step 8 — Re-Enter TDD Development Loop

Read and execute `commands/develop.md`.

> **Only process task rows that live under a `## Amendments (PR Review Round <N>)` heading AND have `Status: ⏳ Pending`.**

The filter is **section-based**, not content-based (pre-C3 it matched `Notes contains \`PR-comment:\`` — section-based is the durable signal).

All Phase 3 rules apply (TDD/direct paths, worktree isolation, sequential within repo, parallel across repos, squash-merge on approval).

After all new tasks are ✅ Done, proceed to Step 8b.

### Step 8b — Re-trigger Phase 5 hardening on affected repos

Phase 7 amendments land new production code that has never been through the 90% coverage gate. For each repo where this batch added at least one task, check `T-TEST-<RepoName>` Status:

- **`Status: ✅ Done`** → re-trigger:
  1. Set `T-TEST-<RepoName>` → `🔧 In Progress` (legal `✅ Done → 🔧 In Progress` per `tracker-schema.md`; overwrites `Started` timestamp on T-TEST row — original Phase 5 start is preserved in `Test hardening started` Workflow Metrics).
  2. Invoke `commands/test.md` Step 1 (auto-harden Tester) and Step 2 (Reviewer) for this repo.
  3. On Reviewer `APPROVED` → set `T-TEST-<RepoName>` → `✅ Done`, stamp `Completed`.
  4. On Reviewer `CHANGES_REQUESTED` → loop per standard Phase 5 handling.

- **`Status` is anything else** → Phase 5 hasn't completed; upcoming run will include the amendment code. Skip.

Multiple repos re-triggered in parallel (`run_in_background: true`). Sequential within each repo.

The Workflow Metrics `Test hardening started` / `Test hardening completed`
timestamps are NOT re-set by this step — they record Phase 5's first run, and Phase 7's re-trigger is recorded by `PR review response completed`.

After every re-triggered `T-TEST-<RepoName>` returns to ✅ Done, proceed to Step 9.

### Step 9 — Record Completion and Offer PR Replies

Update Workflow Metrics: set `PR review response completed` to `date -u +"%Y-%m-%d %H:%M UTC"`.

Create a **new tracker-update commit** — **Do NOT amend** (HEAD is a Phase 7 task squash, not the Phase 6 tracker commit).

Determine whether workspace is a git repo:
```bash
git -C ai/<YYYY-MM-DD>-<work-item-id>/ rev-parse --is-inside-work-tree 2>/dev/null
```

**If the workspace IS a git repo**

Stage and commit the per-workflow dir (plan included — a Phase 7 `[a] Expand scope` may have appended a `## Plan Amendment — Ad-Hoc Round <N>` section; staging the dir is a no-op if the plan is unchanged):

```bash
git add ai/<YYYY-MM-DD>-<work-item-id>/
git commit -m "$(cat <<'EOF'
#<STORY-ID> #TPR-RESP: record PR review response completion

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git push origin <feature-branch>
```

**If the workspace is NOT a git repo**

Sync tracker **and plan** into each affected repo via Read+Write tools (not `cp` — `bash-write-guard` blocks Bash writes to `ai/`). Plan sync required because a `MODE: plan-amendment` via `[a] Expand scope` appends to the workspace plan; without re-sync the per-repo copy stays frozen at pre-amendment state:

- Read `ai/<YYYY-MM-DD>-<work-item-id>/tracker.md` (workspace) → Write to `<REPO_PATH>/ai/<YYYY-MM-DD>-<work-item-id>/tracker.md`
- Read `ai/<YYYY-MM-DD>-<work-item-id>/plan.md` (workspace)    → Write to `<REPO_PATH>/ai/<YYYY-MM-DD>-<work-item-id>/plan.md`

Then commit and push:

```bash
git -C "<REPO_PATH>" add ai/<YYYY-MM-DD>-<work-item-id>/
git -C "<REPO_PATH>" commit -m "$(cat <<'EOF'
#<STORY-ID> #TPR-RESP: record PR review response completion

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
git -C "<REPO_PATH>" push origin <feature-branch>
```

(If the plan was not amended this round — no `Plan Amendment — Ad-Hoc Round` section was appended — staging the dir is a no-op for the plan file; the commit still lands via the tracker delta.)

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

**Precondition guard (NON-NEGOTIABLE):** T2 is only meaningful when this
cycle actually produced a comment-analysis report. Verify before invoking:

```bash
ls "ai/<YYYY-MM-DD>-<work-item-id>"/pr-comment-analysis-report-*.md >/dev/null 2>&1 \
  || { echo "Step 10 skipped: no pr-comment-analysis-report-*.md in workflow dir (T2 has no trigger source)" >&2; exit 0; }
```

If no analysis report exists in the workflow dir, **skip the metrics
invocation** — firing T2 here would record a phantom row in
`_metrics-log.csv` with empty `p7_duration_minutes` (the symptom this
guard exists to prevent). The Step 2 early-exit at "no unresolved
comments" already covers most paths; this Step 10 guard is the
defence-in-depth check.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/metrics_collector.py" \
    "ai/<YYYY-MM-DD>-<work-item-id>" \
    --round <n>
```

Round = count of distinct `pr-comment-analysis-report-*.md` files in the workflow dir after this cycle's analysis was written. Aggregator computes `p7_duration_minutes` (`PR created` → `PR review response completed`) and `pr_review_rounds`. Exit: `0` success, `1` validation failure (surface `.error.md`), `2` precondition unmet (including "no analysis report"). Non-zero does not abort P7 — metrics are non-blocking.

---

## Re-Entry

Phase 7 can run multiple times (each discovers newly unresolved threads, creates a fresh `PR-comment:` task batch, runs the dev loop for those tasks only — prior tasks stay Done).

## Single-Repo Backward Compatibility

Single-repo behaves identically — one Reviewer, one gate, one Planner, one dev loop.
