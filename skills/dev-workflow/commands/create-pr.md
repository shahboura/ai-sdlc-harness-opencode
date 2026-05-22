# Phase 6: PR Creation

> Authoritative references: [provider-resolver](../context/provider-resolver.md), [summary-render](../context/summary-render.md), [timestamp](../context/timestamp.md), [parallel-lane](../context/parallel-lane.md), [naming-templates](../context/naming-templates.md), [workflow-paths](../context/workflow-paths.md)

> Naming-config (M-15 IMPL-15-04): PR-title templates are read from `.claude/context/naming-config.md` per CC-01.8. The chosen `pr_title_format:` overlays the active provider's `pr-conventions.md`; conflicts are surfaced at bootstrap time (P0 Step 5c) — not at PR-creation time.

> **Path resolution (M-14 IMPL-14-02)**: every inline reference to `ai/plans/<id>.md` / `ai/tasks/<id>.md` in this command is the **legacy** layout. Resolve the actual paths via `ai/*-<work-item-id>/plan.md` / `tracker.md` (new canonical layout per [workflow-paths](../context/workflow-paths.md)); fall back to the legacy paths during the migration window. The shared file is the SSOT — when the two diverge, the shared file wins.

<!-- Changed by: dev-workflow-plan.md [M-06] [IMPL-06-01, IMPL-06-04]
     Reason: Cite provider-resolver / summary-render / timestamp + add canonical-spec header per CC-04.3 / CC-07.3.
     CC conventions applied: CC-04.3, CC-07.3. -->

**Phase**: 6
**Actor**: Orchestrator, then Human gate

## Prerequisites

- Tests approved (Phase 5 complete).
- ALL tasks (dev + test) are ✅ Done in the tracker.
- `Test hardening completed` timestamp is set.
- If in direct phase mode, verify by reading the tracker.

## Steps

### Step 1 — Read Repo Configuration

```bash
cat .claude/context/repos-paths.md
cat .claude/context/language-config.md
```

Parse the tracker's **Repo Status** section to identify all affected repos and their
feature branches.

### Step 2 — Pre-PR Holistic Review (per repo, parallel)

For each affected repo, invoke `@ai-sdlc-reviewer` with `mode: pre-pr` and
`run_in_background: true` (name: `reviewer-prepr-<repo-name>`):

```
@ai-sdlc-reviewer Pre-PR holistic review for Story $ARGUMENTS.

MODE: pre-pr

[Include LANGUAGE_CTX — reviewer role: include build-cmd, test-cmd, coverage-cmd; omit format-cmd]
(Templates: ../context/prompt-templates.md)

REVIEW CONTEXT:
- Repo path: <local repo path>
- Feature branch: <team-name>/feature/<id>-<slug>
- Default branch: <main | master>
- Plan path: <ai/plans/...>
- Story ID: #<STORY-ID>

Review the entire feature branch against the full plan and conventions.
Produce the Pre-PR Review Report. See agents/reviewer/index.md for the
pre-pr mode instructions and report format.
```

Wait for all reviewer background agents to complete (one per repo).

### Step 2b — Cross-Repo Contract Reconciliation (Multi-Repo Only)

*(Skip this step entirely for single-repo stories or when the plan declares no
Cross-repo contracts.)*

For each contract listed in the plan's **Cross-repo contracts** section:

1. Locate the contract's row in **section 3b — Cross-Repo Contract Verification** of every
   per-repo Pre-PR Review Report. There must be exactly two entries (one Producer + one
   Consumer; or one Producer + N Consumers for fan-out contracts).
2. Compare the `Observed Signature (this repo)` strings across the entries — they MUST be
   byte-identical (after whitespace normalisation). The compare is purely lexical; do NOT
   re-read code from any repo (rule #1 forbids orchestrator-side source reading).
3. If any contract has no matching Producer entry, no matching Consumer entry, or its
   Observed Signatures differ across repos, classify as **drift**.

Build a reconciliation summary:

```
## Cross-Repo Contract Reconciliation

| Contract ID | Status | Detail |
|-------------|--------|--------|
| C1 | ✅ Match | Producer (AuthService) and Consumer (ApiGateway) signatures agree |
| C2 | ❌ Drift | Producer signature `Payload={...}` ≠ Consumer signature `Payload={...}` |
| C3 | ⚠️ Missing side | Producer present (BillingService) but no Consumer entry recorded |
```

**If every contract is ✅ Match:** continue to Step 3 as normal.

**If any contract has ❌ Drift or ⚠️ Missing side:** treat it the same as a `CHANGES_REQUESTED`
verdict from one of the repo reviewers — present the reconciliation summary alongside the
per-repo reports at Step 3, and offer the Step 4 fix-or-override choice. **Do not auto-route
fixes** to either repo: contract drift is a design-level judgement (producer wrong vs
consumer wrong vs plan stale), and the human must decide which side moves. Once the human
picks a side, fixes route to that repo's Developer via the normal Step 4 fixup flow; the
other repo's Developer is not invoked.

### Step 3 — Present Pre-PR Review Report(s) to Human

For each repo, display the full Pre-PR Review Report returned by the Reviewer.
For multi-repo stories, present all reports together, clearly separated by repo.

Then present the gate:

**If all repos are `✅ APPROVED` or `⚠️ APPROVED WITH CONCERNS`:**

```
## Pre-PR Review Complete

<display report(s)>

All repos reviewed. Ready to create PR(s).

Options:
  [1] APPROVED — open the PR(s) for review and merge as normal.
  [2] DRAFT — open the PR(s) in draft state. The harness's internal review is
      complete, but the PR is intentionally not yet open for external team review
      (e.g. waiting on a dependent PR in another repo, or on out-of-band sign-off).
  [3] CHANGES — describe changes you want made first.
  [4] REQUEST <description> — submit an ad-hoc request (issue found while exercising
      the feature, out-of-scope idea, or change against the approved plan). Triaged
      against the plan; in-scope items create tasks under a separate `## Ad-hoc Tasks`
      heading; out-of-scope items are surfaced back to you with explicit options.

Type 1, 2, describe changes for option 3, or `REQUEST <text>` for option 4.
```

**If any repo has `❌ CHANGES REQUESTED`:**

```
## Pre-PR Review — Issues Found

<display report(s), highlighting critical issues>

Critical issues were found in <repo(s)>. Options:
  [1] Fix before creating PR (recommended) — I'll invoke the Developer
      to address the critical issues, then re-run the pre-PR review.
  [2] Proceed anyway — create the PR with the issues noted above.

What would you like to do?
```

### Step 4 — Handle Fix Loop (if option [1] chosen)

If the human chooses to fix:

1. For each repo with critical issues, invoke `@ai-sdlc-developer` with the critical issue
   list, working directly on the feature branch (no worktree needed):
   ```
   Fix the following pre-PR review issues on branch <feature-branch> in <repo-path>:
   <critical issues from the report>

   For each fix commit, use the fixup! format so the orchestrator can squash it cleanly:

     fixup! <exact subject of the task commit whose files this fix touches>

   To find the target: run `git -C "<repo-path>" log <default-branch>..<feature-branch> --oneline`
   and identify the task commit that last modified the files your fix touches. Copy its exact
   subject (full first line, verbatim) as the fixup! suffix. If the fix touches files from
   multiple task commits, target the most recently committed one.

   Do NOT use the Co-Authored-By trailer on fixup! commits — they will be squashed away.
   ```

2. After the Developer completes, squash all `fixup!` commits into their target task commits
   non-interactively, per repo:
   ```bash
   GIT_SEQUENCE_EDITOR=true git -C "<repo-path>" rebase -i --autosquash <default-branch>
   ```
   If the rebase exits non-zero, abort and escalate:
   ```bash
   git -C "<repo-path>" rebase --abort
   # Present the conflict output to the human and pause the workflow.
   ```

3. After a successful rebase, re-derive the commit hashes for each task and refresh the
   tracker's **Commit(s)** column before it is committed in Step 6:
   ```bash
   git -C "<repo-path>" log <default-branch>..<feature-branch> --oneline
   ```
   Match each line to its task by the Task ID in the commit subject (e.g. `#T2`).
   Update the `Commit(s)` cell for every affected task row in the working-tree tracker.

4. Re-run Step 2 (pre-PR review) for the affected repos.
5. Re-present Step 3 with the updated report.

Repeat until the human approves or explicitly overrides.

### Step 5 — HUMAN GATE #3

Capture the human's choice from the multi-choice prompt in Step 3 and map it to
a `PR_MODE` value that will be passed into `pr-creator`:

| Human chose | PR_MODE |
|-------------|---------|
| `1` / `APPROVED` | `standard` |
| `2` / `DRAFT` | `draft` |
| `3` / changes described | (re-enter Step 4 fix loop; do not proceed) |
| `4` / `REQUEST <text>` | (invoke `commands/handle-request.md` with `Source: gate-3`, `Submission phase: 6`; do not proceed) |

For option `4`, invoke `commands/handle-request.md` with the verbatim request text. After
the request batch is fully processed (Step 8 of handle-request.md returns to this gate),
re-run Step 2 (Pre-PR Holistic Review) so the Reviewer sees the new ad-hoc task commits,
then re-present Step 3 with the updated report.

Hold `PR_MODE` in orchestrator state; it flows into the pr-creator invocation in Step 7.

Once the gate is cleared (option 1 or 2), proceed to Step 6.

### Step 6 — Commit the Task Tracker

**Before creating the PRs**, commit the task tracker for the first (and only) time.

First, determine whether the workspace `ai/<YYYY-MM-DD>-<work-item-id>/` directory is inside a git repository:

```bash
git -C ai/<YYYY-MM-DD>-<work-item-id>/ rev-parse --is-inside-work-tree 2>/dev/null
```

**Case A — workspace IS a git repo** (exits 0 — single-repo stories where the workspace itself is the target repository; the plan, tracker, test outline, and code all live in the same git tree):

The directory-level `git add` below picks up the tracker and the test outline together — the tracker stayed uncommitted from Phase 2 per orchestrator rule #8, and the test outline stayed uncommitted alongside it (preflight Step 3 only committed `plan.md`).

```bash
git add ai/<YYYY-MM-DD>-<work-item-id>/
git commit -m "$(cat <<'EOF'
#<STORY-ID> #TTRACKER: add task tracker and test outline with final workflow state

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

**Case B — workspace is NOT a git repo** (exits non-zero — the multi-repo design case, where the workspace is a standalone directory holding `ai/` artifacts and the affected repos are cloned alongside it; this is the design's headline case and what every multi-repo story uses):

For each affected repo, copy the tracker, plan, and test outline into that repo's `ai/` directories, then commit from the repo. All three are sibling P2 artifacts (per [workflow-paths](../context/workflow-paths.md)) and must land together so the PR commit is self-contained.

**Do NOT use `cp`.** The `bash-write-guard` hook blocks shell mutations to any path
containing `/ai/` by design — `ai/` is owned by Read/Write tool calls, never by
shell-driven mutations. Use the **Read** tool to read each workspace file and the **Write**
tool to write it to the repo path:

- Read `ai/<YYYY-MM-DD>-<work-item-id>/tracker.md` (workspace)      → Write to `<REPO_PATH>/ai/<YYYY-MM-DD>-<work-item-id>/tracker.md`
- Read `ai/<YYYY-MM-DD>-<work-item-id>/plan.md` (workspace)         → Write to `<REPO_PATH>/ai/<YYYY-MM-DD>-<work-item-id>/plan.md`
- Read `ai/<YYYY-MM-DD>-<work-item-id>/test-outline.md` (workspace) → Write to `<REPO_PATH>/ai/<YYYY-MM-DD>-<work-item-id>/test-outline.md`

Then commit from the repo:

```bash
# For each affected repo at <REPO_PATH>:
git -C "<REPO_PATH>" add ai/<YYYY-MM-DD>-<work-item-id>/
git -C "<REPO_PATH>" commit -m "$(cat <<'EOF'
#<STORY-ID> #TTRACKER: add task tracker, plan, and test outline with final workflow state

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

The tracker, plan, and test outline now travel with the feature branch. All Step 9 amend operations target the same repo commit.

### Step 7 — Create PRs (One Per Repo)

For each affected repo, invoke the **pr-creator** skill with the `PR_MODE` selected at
GATE #3. Include the mode as an explicit context block in the invocation:

```
/pr-creator $ARGUMENTS <team-name> <repo-name>

PR_MODE: <standard | draft>
```

The pr-creator will:
1. Run Step 0 idempotency check — query `pr.find_for_branch`; if an open PR exists,
   surface the reuse/fail prompt before any push.
2. Push the repo's feature branch to the remote.
3. Create the PR/MR via the configured git provider (passing `--draft` / `draft: true`
   when `PR_MODE: draft`).
4. Link the PR/MR to the work item via the configured work item provider.

### Step 8 — Cross-Reference PRs (Multi-Repo Only)

After all PRs are created, update each PR description to include links to the
related PRs in other repos:

```
## Related PRs
- AuthService: PR #<id> — <url>
- BillingService: PR #<id> — <url>
```

### Step 9 — Record Final Metric

After all PRs are created (or reused), stamp `PR created` in the tracker — this is a hard precondition for Step 10's T1 metrics. Do NOT advance until the stamp is in place.

**Sequence:** capture `PR_CREATED_TS=$(date -u +"%Y-%m-%d %H:%M UTC")`; use the **Edit** tool to add or update `| **PR created** | <PR_CREATED_TS> |` in the `## Workflow Metrics` block at `ai/<YYYY-MM-DD>-<work-item-id>/tracker.md` (canonical row format per [`tracker-field-schema.md`](../../../agents/shared/tracker-field-schema.md)); re-read the tracker to verify; then update the remote per the Create-path / Reuse-path bash blocks below.

**Read pr-creator's `Reuse:` flag** for each repo from its output contract (per
`skills/pr-creator/SKILL.md` → Step 0). The flag determines which of the two paths
below applies per repo. In multi-repo stories some repos may be `Reuse: true` and
others `Reuse: false`; handle each independently.

#### Create path (`Reuse: false`) — amend + force-push

The Step 6 tracker commit was made earlier in this run and pushed in Step 7's
pr-creator. No other commits have landed on the remote between then and now (the
window is seconds). Amend the just-pushed tracker commit to include the metric and
force-push:

**If the workspace is a git repo:**

```bash
git add ai/<YYYY-MM-DD>-<work-item-id>/
git commit --amend --no-edit
git push --force-with-lease origin <feature-branch>
```

The amend rewrites the tracker commit's SHA, so the remote (already pushed in Step 7 via
`pr-creator`) must be force-pushed to stay in sync. `--force-with-lease` is safe because
no other commits should have landed on the remote between Step 7 and now.

**If the workspace is NOT a git repo** (tracker was copied into the repo in Step 6):

Sync the updated tracker back into the repo using the **Read + Write** tools (not `cp` —
the `bash-write-guard` hook blocks Bash writes to `ai/` paths):

- Read `ai/<YYYY-MM-DD>-<work-item-id>/tracker.md` (workspace) → Write to `<REPO_PATH>/ai/<YYYY-MM-DD>-<work-item-id>/tracker.md`

Then amend the repo's tracker commit and force-push:

```bash
git -C "<REPO_PATH>" add ai/<YYYY-MM-DD>-<work-item-id>/
git -C "<REPO_PATH>" commit --amend --no-edit
git -C "<REPO_PATH>" push --force-with-lease origin <feature-branch>
```

#### Reuse path (`Reuse: true`) — fresh commit + fast-forward push

Do NOT amend + force-push in reuse mode: force-push noise on the open PR orphans inline comments, and amend would overwrite an existing `PR created` metric from a prior run. Instead, create a **fresh** tracker-update commit (only if `PR created` is still `—`) and fast-forward push.

**Set the metric only if it's still `—`.** If already populated, skip the commit.

**Workspace is a git repo:**
```bash
git add ai/<YYYY-MM-DD>-<work-item-id>/
git commit -m "#<STORY-ID> #TTRACKER: record PR created timestamp on reuse

Co-Authored-By: Claude Code <noreply@anthropic.com>"
git push origin <feature-branch>
```

**Workspace is NOT a git repo:** sync tracker via Read+Write into `<REPO_PATH>/ai/<YYYY-MM-DD>-<work-item-id>/tracker.md`, then `git -C "<REPO_PATH>" add … commit … push`.

Fast-forward push — no `--force-with-lease` needed.

### Step 10 — T1 Metrics Collection

Per the P9 metrics-collector contract (`skills/metrics-collector/SKILL.md`),
P6 triggers metrics aggregation at **T1** with `--round 0` once the `PR
created` timestamp has been stamped. The aggregator is a pure subprocess —
no agent, no LLM hop — that reads the just-stamped tracker, computes the six
required workflow aggregates, writes a per-workflow `metrics-report.md` and
appends one row to the workspace-level `ai/_metrics-log.csv`.

**Precondition guard (NON-NEGOTIABLE):** Step 9's `PR created` stamp must exist before this runs — otherwise the row records empty `cycle_time_minutes`. The collector also enforces this defensively (exit 2 + `.error.md`); the call-site pre-check is for clarity:

```bash
grep -qE '\*\*PR created\*\*|^PR created:' \
  "ai/<YYYY-MM-DD>-<work-item-id>/tracker.md" \
  || { echo "Step 10 skipped: PR created not stamped (re-run Step 9)" >&2; exit 0; }

python3 "${CLAUDE_PLUGIN_ROOT}/scripts/metrics_collector.py" \
    "ai/<YYYY-MM-DD>-<work-item-id>" \
    --round 0
```

Exit semantics: `0` success, `1` validation failure (`.error.md` written, CSV not appended), `2` precondition unmet (PR created absent / workflow dir / tracker missing).

On exit `1`/`2` the orchestrator surfaces the `.error.md` content verbatim
to the human but **does not** abort PR creation — the PR is already on the
remote, the metrics row is a non-blocking observation. T2 (next review
cycle) will re-attempt the aggregation against the corrected tracker.

---

## Single-Repo Backward Compatibility

If only one repo is affected, this behaves identically — one pre-PR review,
one human gate, one PR created, no cross-referencing needed.
